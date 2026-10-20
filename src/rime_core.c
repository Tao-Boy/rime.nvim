/*
 * rime_core: a Lua (5.1 / LuaJIT) C module binding librime for rime.nvim.
 *
 * librime is loaded at runtime with dlopen()/LoadLibrary(), so building
 * this module needs only a C compiler: the Lua and librime headers are
 * vendored under src/.
 *
 * Threading model
 * ---------------
 * Everything that can take a noticeable amount of time (loading librime,
 * RimeInitialize, deployment, syncing user data, switching schema) runs
 * on a worker thread started by start()/redeploy()/sync()/select_schema().
 * While such a job runs the module is "busy" and every session call made
 * from Lua returns immediately without touching librime, so the editor
 * never waits for Rime.  Lua learns about finished jobs and librime
 * notifications by calling poll(), which only copies queued events.
 *
 * Key processing (process(), select(), ...) runs on the caller's thread:
 * librime handles a key in microseconds, and processing it synchronously
 * keeps the order of keys and inserted text exact.
 *
 * Only one Rime session exists; it is owned by this module.
 */

#if !defined(_WIN32) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE /* RTLD_DEEPBIND, dladdr */
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lua/lua.h"
#include "lua/lauxlib.h"
#include "rime/rime_api.h"

#ifdef _WIN32
#include <windows.h>
#include <process.h>
typedef HANDLE thread_t;
typedef CRITICAL_SECTION mutex_t;
#define mutex_init(m) InitializeCriticalSection(m)
#define mutex_lock(m) EnterCriticalSection(m)
#define mutex_unlock(m) LeaveCriticalSection(m)
#define EXPORT __declspec(dllexport)
#else
#include <dirent.h>
#include <dlfcn.h>
#include <pthread.h>
typedef pthread_t thread_t;
typedef pthread_mutex_t mutex_t;
#define mutex_init(m) pthread_mutex_init(m, NULL)
#define mutex_lock(m) pthread_mutex_lock(m)
#define mutex_unlock(m) pthread_mutex_unlock(m)
#define EXPORT __attribute__((visibility("default")))
#endif

#define MODULE_VERSION "0.1.0"
#define PATH_SIZE 4096
#define ERR_SIZE 512

typedef RimeApi *(*rime_get_api_fn)(void);

/* ------------------------------------------------------------------ */
/* Global state                                                        */
/* ------------------------------------------------------------------ */

enum job_kind { JOB_NONE, JOB_START, JOB_REDEPLOY, JOB_SYNC, JOB_SCHEMA };

static const char *job_names[] = {"none", "start", "redeploy", "sync",
                                  "schema"};

static mutex_t g_mx;     /* protects g_busy, g_job, g_thread_live, g_error */
static mutex_t g_evmx;   /* protects the event queue */
static int g_mx_ready = 0;

static RimeApi *g_api = NULL;
static void *g_lib = NULL;
static int g_setup_done = 0;    /* RimeSetup may only run once per process */
static int g_initialized = 0;   /* between RimeInitialize and RimeFinalize */
static RimeSessionId g_session = 0;

static int g_busy = 0;          /* a job is running on the worker thread */
static int g_thread_live = 0;   /* a worker thread needs joining */
static thread_t g_thread;
static enum job_kind g_job = JOB_NONE;
static char g_error[ERR_SIZE] = "";

/* Job arguments and traits; written only while no job runs. */
static char g_lib_path[PATH_SIZE];
static char g_shared_dir[PATH_SIZE];
static char g_user_dir[PATH_SIZE];
static char g_log_dir[PATH_SIZE];
static char g_schema[256];
static char g_job_arg[256];
static int g_log_level = 2;
static int g_full_check = 0;

/* ------------------------------------------------------------------ */
/* Event queue (librime notifications and job results)                 */
/* ------------------------------------------------------------------ */

#define EVENT_MAX 128

typedef struct {
  char type[32];
  char value[256];
} event_t;

static event_t g_events[EVENT_MAX];
static int g_ev_head = 0, g_ev_count = 0;

static void push_event(const char *type, const char *value) {
  mutex_lock(&g_evmx);
  int idx;
  if (g_ev_count == EVENT_MAX) { /* drop the oldest */
    g_ev_head = (g_ev_head + 1) % EVENT_MAX;
    g_ev_count--;
  }
  idx = (g_ev_head + g_ev_count) % EVENT_MAX;
  snprintf(g_events[idx].type, sizeof g_events[idx].type, "%s",
           type ? type : "");
  snprintf(g_events[idx].value, sizeof g_events[idx].value, "%s",
           value ? value : "");
  g_ev_count++;
  mutex_unlock(&g_evmx);
}

static void on_notification(void *ctx, RimeSessionId sid, const char *type,
                            const char *value) {
  (void)ctx;
  (void)sid;
  push_event(type, value);
}

/* ------------------------------------------------------------------ */
/* Loading librime                                                     */
/* ------------------------------------------------------------------ */

/* On ELF systems Neovim exports LuaJIT's lua_* symbols, and a library
 * loaded later binds its own lua_* references to those before its own
 * dependencies.  librime-lua (a plugin, or merged into librime) links
 * Lua 5.4 and would crash calling LuaJIT, so librime and its plugins
 * are loaded with RTLD_DEEPBIND, which makes them prefer their own
 * dependencies.  macOS (two-level namespaces) and Windows bind imports
 * per library and do not need this. */
#if !defined(_WIN32) && defined(RTLD_DEEPBIND)
#define DLOPEN_FLAGS (RTLD_NOW | RTLD_LOCAL | RTLD_DEEPBIND)
#elif !defined(_WIN32)
#define DLOPEN_FLAGS (RTLD_NOW | RTLD_LOCAL)
#endif

static void *lib_open(const char *path) {
#ifdef _WIN32
  return (void *)LoadLibraryA(path);
#else
  return dlopen(path, DLOPEN_FLAGS);
#endif
}

static void *lib_sym(void *lib, const char *name) {
#ifdef _WIN32
  return (void *)GetProcAddress((HMODULE)lib, name);
#else
  return dlsym(lib, name);
#endif
}

static const char *default_lib_names[] = {
#if defined(_WIN32)
    "rime.dll",
#elif defined(__APPLE__)
    "librime.1.dylib",
    "/opt/homebrew/lib/librime.1.dylib",
    "/usr/local/lib/librime.1.dylib",
    "/Library/Input Methods/Squirrel.app/Contents/Frameworks/librime.1.dylib",
#else
    "librime.so.1",
    "librime.so",
#endif
    NULL};

/* librime dlopen()s the plugins in <libdir>/rime-plugins when it starts.
 * Loading them first, with DLOPEN_FLAGS, makes librime reuse these
 * handles, so the plugins resolve symbols as described above. */
static void preload_plugins(void) {
#if !defined(_WIN32) && defined(RTLD_DEEPBIND)
  Dl_info info;
  char dir[PATH_SIZE], path[PATH_SIZE + 256];
  char *slash;
  DIR *d;
  struct dirent *ent;
  /* g_api points into librime's data: find the file it comes from. */
  if (!dladdr((void *)g_api, &info) || !info.dli_fname) return;
  snprintf(dir, sizeof dir, "%s", info.dli_fname);
  slash = strrchr(dir, '/');
  if (!slash) return;
  snprintf(slash, sizeof dir - (size_t)(slash - dir), "/rime-plugins");
  d = opendir(dir);
  if (!d) return;
  while ((ent = readdir(d)) != NULL) {
    size_t n = strlen(ent->d_name);
    if (n < 4 || strcmp(ent->d_name + n - 3, ".so") != 0) continue;
    snprintf(path, sizeof path, "%s/%s", dir, ent->d_name);
    dlopen(path, RTLD_NOW | RTLD_GLOBAL | RTLD_DEEPBIND);
  }
  closedir(d);
#endif
}

/* glog, which librime logs with, also prints errors to stderr, where they
 * would be drawn over Neovim's screen.  Keep them in the log files only:
 * set glog's flags through their (C++ mangled) symbols when present. */
static void quiet_stderr(void *lib) {
#ifndef _WIN32
  int *threshold = (int *)lib_sym(lib, "_ZN3fLI21FLAGS_stderrthresholdE");
  char *also = (char *)lib_sym(lib, "_ZN3fLB21FLAGS_alsologtostderrE");
  if (threshold) *threshold = 4; /* above FATAL: never */
  if (also) *also = 0;
#else
  (void)lib;
#endif
}

/* Called on the worker thread; sets g_error on failure. */
static int load_librime(void) {
  void *lib = NULL;
  rime_get_api_fn get_api;
  if (g_api) return 1;
  if (g_lib_path[0]) {
    lib = lib_open(g_lib_path);
  } else {
    for (int i = 0; default_lib_names[i] && !lib; i++)
      lib = lib_open(default_lib_names[i]);
  }
  if (!lib) {
#ifdef _WIN32
    snprintf(g_error, ERR_SIZE, "cannot load librime (%s): error %lu",
             g_lib_path[0] ? g_lib_path : "rime.dll", GetLastError());
#else
    const char *err = dlerror();
    snprintf(g_error, ERR_SIZE, "cannot load librime: %s",
             err ? err : "not found");
#endif
    return 0;
  }
  get_api = (rime_get_api_fn)lib_sym(lib, "rime_get_api");
  if (!get_api || !(g_api = get_api())) {
    snprintf(g_error, ERR_SIZE, "rime_get_api not found in librime");
    return 0;
  }
  g_lib = lib;
  quiet_stderr(lib);
  preload_plugins();
  return 1;
}

/* ------------------------------------------------------------------ */
/* Worker jobs                                                         */
/* ------------------------------------------------------------------ */

static void fill_traits(RimeTraits *traits) {
  RIME_STRUCT_INIT(RimeTraits, *traits);
  traits->shared_data_dir = g_shared_dir[0] ? g_shared_dir : NULL;
  traits->user_data_dir = g_user_dir[0] ? g_user_dir : NULL;
  traits->distribution_name = "rime.nvim";
  traits->distribution_code_name = "rime.nvim";
  traits->distribution_version = MODULE_VERSION;
  traits->app_name = "rime.nvim";
  traits->min_log_level = g_log_level;
  traits->log_dir = g_log_dir[0] ? g_log_dir : NULL;
}

/* The first lookup pages in the dictionaries, which can take a while;
 * do it here, on the worker thread, instead of on the first key. */
static void warm_up(void) {
  if (g_api->process_key(g_session, 'a', 0)) {
    RIME_STRUCT(RimeContext, ctx);
    if (g_api->get_context(g_session, &ctx)) g_api->free_context(&ctx);
  }
  g_api->clear_composition(g_session);
}

/* Initialize, deploy if needed and open the session. */
static int bring_up(int full_check) {
  RimeTraits traits = {0};
  fill_traits(&traits);
  if (!g_setup_done) {
    g_api->setup(&traits);
    g_api->set_notification_handler(on_notification, NULL);
    g_setup_done = 1;
  }
  g_api->initialize(&traits);
  g_initialized = 1;
  if (g_api->start_maintenance(full_check))
    g_api->join_maintenance_thread();
  g_session = g_api->create_session();
  if (!g_session) {
    snprintf(g_error, ERR_SIZE, "failed to create a Rime session");
    return 0;
  }
  if (g_schema[0] && !g_api->select_schema(g_session, g_schema))
    push_event("warning", "schema not found");
  warm_up();
  return 1;
}

static void tear_down(void) {
  if (g_session) {
    g_api->destroy_session(g_session);
    g_session = 0;
  }
  if (g_initialized) {
    g_api->finalize();
    g_initialized = 0;
  }
}

static int run_job(enum job_kind kind) {
  switch (kind) {
  case JOB_START:
    if (!load_librime()) return 0;
    if (g_session) return 1;
    return bring_up(g_full_check);
  case JOB_REDEPLOY:
    if (!load_librime()) return 0;
    tear_down();
    return bring_up(1);
  case JOB_SYNC:
    if (!g_initialized) return 0;
    if (g_api->sync_user_data()) g_api->join_maintenance_thread();
    return 1;
  case JOB_SCHEMA:
    if (!g_session) return 0;
    if (!g_api->select_schema(g_session, g_job_arg)) {
      snprintf(g_error, ERR_SIZE, "cannot select schema '%s'", g_job_arg);
      return 0;
    }
    snprintf(g_schema, sizeof g_schema, "%s", g_job_arg);
    warm_up();
    return 1;
  default:
    return 0;
  }
}

#ifdef _WIN32
static unsigned __stdcall worker(void *arg)
#else
static void *worker(void *arg)
#endif
{
  enum job_kind kind = (enum job_kind)(size_t)arg;
  int ok = run_job(kind);
  char err[ERR_SIZE];
  mutex_lock(&g_mx);
  snprintf(err, sizeof err, "%s", g_error);
  g_busy = 0;
  g_job = JOB_NONE;
  mutex_unlock(&g_mx);
  push_event(ok ? "job_done" : "job_failed", job_names[kind]);
  if (!ok) push_event("error", err);
  return 0;
}

static void join_worker(void) {
  if (!g_thread_live) return;
#ifdef _WIN32
  WaitForSingleObject(g_thread, INFINITE);
  CloseHandle(g_thread);
#else
  pthread_join(g_thread, NULL);
#endif
  g_thread_live = 0;
}

/* Start a job on the worker thread.  Returns 0 when a job is running. */
static int launch(enum job_kind kind) {
  mutex_lock(&g_mx);
  if (g_busy) {
    mutex_unlock(&g_mx);
    return 0;
  }
  mutex_unlock(&g_mx);
  /* The previous worker has finished (g_busy == 0); reap it. */
  join_worker();
  mutex_lock(&g_mx);
  g_busy = 1;
  g_job = kind;
  g_error[0] = '\0';
  mutex_unlock(&g_mx);
#ifdef _WIN32
  g_thread = (HANDLE)_beginthreadex(NULL, 0, worker, (void *)(size_t)kind, 0,
                                    NULL);
  int failed = g_thread == 0;
#else
  int failed = pthread_create(&g_thread, NULL, worker, (void *)(size_t)kind);
#endif
  if (failed) {
    mutex_lock(&g_mx);
    g_busy = 0;
    g_job = JOB_NONE;
    mutex_unlock(&g_mx);
    return -1;
  }
  g_thread_live = 1;
  return 1;
}

/* True when the session may be used from the calling (main) thread. */
static int usable(void) {
  int ok;
  mutex_lock(&g_mx);
  ok = !g_busy && g_session != 0;
  mutex_unlock(&g_mx);
  return ok;
}

/* ------------------------------------------------------------------ */
/* Lua helpers                                                         */
/* ------------------------------------------------------------------ */

static void copy_field(lua_State *L, int idx, const char *key, char *dst,
                       size_t size) {
  lua_getfield(L, idx, key);
  if (lua_isstring(L, -1))
    snprintf(dst, size, "%s", lua_tostring(L, -1));
  else
    dst[0] = '\0';
  lua_pop(L, 1);
}

static void set_str(lua_State *L, const char *key, const char *value) {
  if (!value) return;
  lua_pushstring(L, value);
  lua_setfield(L, -2, key);
}

static void set_int(lua_State *L, const char *key, lua_Integer value) {
  lua_pushinteger(L, value);
  lua_setfield(L, -2, key);
}

static void set_bool(lua_State *L, const char *key, int value) {
  lua_pushboolean(L, value);
  lua_setfield(L, -2, key);
}

/* Push the pending commit text or nil. */
static void push_commit(lua_State *L) {
  RIME_STRUCT(RimeCommit, commit);
  if (g_api->get_commit(g_session, &commit)) {
    lua_pushstring(L, commit.text ? commit.text : "");
    g_api->free_commit(&commit);
  } else {
    lua_pushnil(L);
  }
}

static int is_composing(void) {
  RIME_STRUCT(RimeStatus, status);
  int composing = 0;
  if (g_api->get_status(g_session, &status)) {
    composing = status.is_composing;
    g_api->free_status(&status);
  }
  return composing;
}

/* ------------------------------------------------------------------ */
/* Lifecycle functions                                                 */
/* ------------------------------------------------------------------ */

/* start{shared_data_dir=, user_data_dir=, log_dir=, log_level=,
 *       librime=, schema=, full_check=} -> true | nil, err */
static int l_start(lua_State *L) {
  int r;
  luaL_checktype(L, 1, LUA_TTABLE);
  mutex_lock(&g_mx);
  r = g_busy;
  mutex_unlock(&g_mx);
  if (r) {
    lua_pushnil(L);
    lua_pushstring(L, "busy");
    return 2;
  }
  copy_field(L, 1, "librime", g_lib_path, sizeof g_lib_path);
  copy_field(L, 1, "shared_data_dir", g_shared_dir, sizeof g_shared_dir);
  copy_field(L, 1, "user_data_dir", g_user_dir, sizeof g_user_dir);
  copy_field(L, 1, "log_dir", g_log_dir, sizeof g_log_dir);
  copy_field(L, 1, "schema", g_schema, sizeof g_schema);
  lua_getfield(L, 1, "log_level");
  g_log_level = lua_isnumber(L, -1) ? (int)lua_tointeger(L, -1) : 2;
  lua_getfield(L, 1, "full_check");
  g_full_check = lua_toboolean(L, -1);
  lua_pop(L, 2);
  r = launch(JOB_START);
  if (r <= 0) {
    lua_pushnil(L);
    lua_pushstring(L, r == 0 ? "busy" : "cannot create thread");
    return 2;
  }
  lua_pushboolean(L, 1);
  return 1;
}

static int launch_simple(lua_State *L, enum job_kind kind) {
  int r = launch(kind);
  if (r <= 0) {
    lua_pushnil(L);
    lua_pushstring(L, r == 0 ? "busy" : "cannot create thread");
    return 2;
  }
  lua_pushboolean(L, 1);
  return 1;
}

static int l_redeploy(lua_State *L) {
  if (!g_api) {
    lua_pushnil(L);
    lua_pushstring(L, "not started");
    return 2;
  }
  return launch_simple(L, JOB_REDEPLOY);
}

static int l_sync(lua_State *L) {
  if (!g_initialized) {
    lua_pushnil(L);
    lua_pushstring(L, "not started");
    return 2;
  }
  return launch_simple(L, JOB_SYNC);
}

/* select_schema(id): switching schema loads dictionaries, so it is a job. */
static int l_select_schema(lua_State *L) {
  const char *id = luaL_checkstring(L, 1);
  int busy;
  mutex_lock(&g_mx);
  busy = g_busy;
  mutex_unlock(&g_mx);
  if (busy || !g_session) {
    lua_pushnil(L);
    lua_pushstring(L, busy ? "busy" : "not started");
    return 2;
  }
  snprintf(g_job_arg, sizeof g_job_arg, "%s", id);
  return launch_simple(L, JOB_SCHEMA);
}

/* poll() -> state, events|nil
 * state: "stopped" | "busy" | "ready" | "error" */
static int l_poll(lua_State *L) {
  int busy, n;
  RimeSessionId sid;
  char err[ERR_SIZE];
  mutex_lock(&g_mx);
  busy = g_busy;
  sid = g_session;
  snprintf(err, sizeof err, "%s", g_error);
  mutex_unlock(&g_mx);
  if (busy) lua_pushstring(L, "busy");
  else if (sid) lua_pushstring(L, "ready");
  else if (err[0]) lua_pushstring(L, "error");
  else lua_pushstring(L, "stopped");

  mutex_lock(&g_evmx);
  n = g_ev_count;
  if (n == 0) {
    mutex_unlock(&g_evmx);
    lua_pushnil(L);
    return 2;
  }
  lua_createtable(L, n, 0);
  for (int i = 0; i < n; i++) {
    event_t *ev = &g_events[(g_ev_head + i) % EVENT_MAX];
    lua_createtable(L, 2, 0);
    lua_pushstring(L, ev->type);
    lua_rawseti(L, -2, 1);
    lua_pushstring(L, ev->value);
    lua_rawseti(L, -2, 2);
    lua_rawseti(L, -2, i + 1);
  }
  g_ev_head = 0;
  g_ev_count = 0;
  mutex_unlock(&g_evmx);
  return 2;
}

static int l_ready(lua_State *L) {
  lua_pushboolean(L, usable());
  return 1;
}

/* shutdown(): wait for a running job, close the session, finalize.
 * Must run before exit(): librime's static destructors wait for a running
 * deployment anyway, but by then the objects it uses are destroyed. */
static int l_shutdown(lua_State *L) {
  (void)L;
  join_worker();
  if (g_api) tear_down();
  return 0;
}

static int l_version(lua_State *L) {
  lua_pushstring(L, MODULE_VERSION);
  if (g_api && RIME_API_AVAILABLE(g_api, get_version))
    lua_pushstring(L, g_api->get_version());
  else
    lua_pushnil(L);
  return 2;
}

/* ------------------------------------------------------------------ */
/* Session functions (main thread)                                     */
/* ------------------------------------------------------------------ */

/* process(keycode, mask) -> handled, commit|nil, composing
 * Returns nothing when the session is not usable. */
static int l_process(lua_State *L) {
  int keycode = (int)luaL_checkinteger(L, 1);
  int mask = (int)luaL_optinteger(L, 2, 0);
  int handled;
  if (!usable()) return 0;
  handled = g_api->process_key(g_session, keycode, mask);
  lua_pushboolean(L, handled);
  push_commit(L);
  lua_pushboolean(L, is_composing());
  return 3;
}

/* select(index[, on_current_page=true]) -> ok, commit|nil, composing */
static int l_select(lua_State *L) {
  size_t index = (size_t)luaL_checkinteger(L, 1);
  int page = lua_isnoneornil(L, 2) ? 1 : lua_toboolean(L, 2);
  int ok;
  if (!usable()) return 0;
  if (page && RIME_API_AVAILABLE(g_api, select_candidate_on_current_page))
    ok = g_api->select_candidate_on_current_page(g_session, index);
  else
    ok = g_api->select_candidate(g_session, index);
  lua_pushboolean(L, ok);
  push_commit(L);
  lua_pushboolean(L, is_composing());
  return 3;
}

/* highlight(index_on_page) -> ok */
static int l_highlight(lua_State *L) {
  size_t index = (size_t)luaL_checkinteger(L, 1);
  if (!usable()) return 0;
  if (!RIME_API_AVAILABLE(g_api, highlight_candidate_on_current_page)) {
    lua_pushboolean(L, 0);
    return 1;
  }
  lua_pushboolean(L,
                  g_api->highlight_candidate_on_current_page(g_session, index));
  return 1;
}

/* change_page(backward) -> ok */
static int l_change_page(lua_State *L) {
  int backward = lua_toboolean(L, 1);
  if (!usable()) return 0;
  if (!RIME_API_AVAILABLE(g_api, change_page)) {
    lua_pushboolean(L, 0);
    return 1;
  }
  lua_pushboolean(L, g_api->change_page(g_session, backward));
  return 1;
}

/* delete(index_on_page) -> ok: remove a user-learned candidate. */
static int l_delete(lua_State *L) {
  size_t index = (size_t)luaL_checkinteger(L, 1);
  if (!usable()) return 0;
  if (!RIME_API_AVAILABLE(g_api, delete_candidate_on_current_page)) {
    lua_pushboolean(L, 0);
    return 1;
  }
  lua_pushboolean(L, g_api->delete_candidate_on_current_page(g_session, index));
  return 1;
}

static int l_clear(lua_State *L) {
  (void)L;
  if (usable()) g_api->clear_composition(g_session);
  return 0;
}

/* commit() -> text|nil: commit the raw composition. */
static int l_commit(lua_State *L) {
  if (!usable()) return 0;
  if (!g_api->commit_composition(g_session)) {
    lua_pushnil(L);
    return 1;
  }
  push_commit(L);
  return 1;
}

/* context() -> table|nil
 * { input, preedit, cursor, sel_start, sel_end, preview,
 *   page_no, page_size, last_page, highlighted, select_keys,
 *   candidates = { {text=, comment=}, ... }, labels = { ... } } */
static int l_context(lua_State *L) {
  RIME_STRUCT(RimeContext, ctx);
  if (!usable()) return 0;
  if (!g_api->get_context(g_session, &ctx)) {
    lua_pushnil(L);
    return 1;
  }
  if (ctx.composition.length <= 0 && ctx.menu.num_candidates <= 0) {
    g_api->free_context(&ctx);
    lua_pushnil(L);
    return 1;
  }
  lua_createtable(L, 0, 14);
  if (RIME_API_AVAILABLE(g_api, get_input)) {
    const char *input = g_api->get_input(g_session);
    set_str(L, "input", input ? input : "");
  }
  set_str(L, "preedit", ctx.composition.preedit ? ctx.composition.preedit : "");
  set_int(L, "cursor", ctx.composition.cursor_pos);
  set_int(L, "sel_start", ctx.composition.sel_start);
  set_int(L, "sel_end", ctx.composition.sel_end);
  if (RIME_STRUCT_HAS_MEMBER(ctx, ctx.commit_text_preview))
    set_str(L, "preview", ctx.commit_text_preview);
  set_int(L, "page_no", ctx.menu.page_no);
  set_int(L, "page_size", ctx.menu.page_size);
  set_bool(L, "last_page", ctx.menu.is_last_page);
  set_int(L, "highlighted", ctx.menu.highlighted_candidate_index);
  set_str(L, "select_keys", ctx.menu.select_keys);

  lua_createtable(L, ctx.menu.num_candidates, 0);
  for (int i = 0; i < ctx.menu.num_candidates; i++) {
    RimeCandidate *c = &ctx.menu.candidates[i];
    lua_createtable(L, 0, 2);
    set_str(L, "text", c->text ? c->text : "");
    if (c->comment && c->comment[0]) set_str(L, "comment", c->comment);
    lua_rawseti(L, -2, i + 1);
  }
  lua_setfield(L, -2, "candidates");

  if (RIME_STRUCT_HAS_MEMBER(ctx, ctx.select_labels) && ctx.select_labels) {
    lua_createtable(L, ctx.menu.page_size, 0);
    for (int i = 0; i < ctx.menu.page_size && ctx.select_labels[i]; i++) {
      lua_pushstring(L, ctx.select_labels[i]);
      lua_rawseti(L, -2, i + 1);
    }
    lua_setfield(L, -2, "labels");
  }
  g_api->free_context(&ctx);
  return 1;
}

/* status() -> table|nil */
static int l_status(lua_State *L) {
  RIME_STRUCT(RimeStatus, st);
  if (!usable()) return 0;
  if (!g_api->get_status(g_session, &st)) {
    lua_pushnil(L);
    return 1;
  }
  lua_createtable(L, 0, 9);
  set_str(L, "schema_id", st.schema_id);
  set_str(L, "schema_name", st.schema_name);
  set_bool(L, "disabled", st.is_disabled);
  set_bool(L, "composing", st.is_composing);
  set_bool(L, "ascii_mode", st.is_ascii_mode);
  set_bool(L, "full_shape", st.is_full_shape);
  set_bool(L, "simplified", st.is_simplified);
  set_bool(L, "traditional", st.is_traditional);
  set_bool(L, "ascii_punct", st.is_ascii_punct);
  g_api->free_status(&st);
  return 1;
}

static int l_get_option(lua_State *L) {
  const char *name = luaL_checkstring(L, 1);
  if (!usable()) return 0;
  lua_pushboolean(L, g_api->get_option(g_session, name));
  return 1;
}

static int l_set_option(lua_State *L) {
  const char *name = luaL_checkstring(L, 1);
  int value = lua_toboolean(L, 2);
  if (!usable()) return 0;
  g_api->set_option(g_session, name, value);
  lua_pushboolean(L, 1);
  return 1;
}

/* schemas() -> { {id=, name=}, ... } */
static int l_schemas(lua_State *L) {
  RimeSchemaList list = {0};
  if (!usable()) return 0;
  if (!g_api->get_schema_list(&list)) {
    lua_newtable(L);
    return 1;
  }
  lua_createtable(L, (int)list.size, 0);
  for (size_t i = 0; i < list.size; i++) {
    lua_createtable(L, 0, 2);
    set_str(L, "id", list.list[i].schema_id);
    set_str(L, "name", list.list[i].name);
    lua_rawseti(L, -2, (int)i + 1);
  }
  g_api->free_schema_list(&list);
  return 1;
}

/* dirs() -> { shared=, user=, sync= } as librime resolved them. */
static int l_dirs(lua_State *L) {
  if (!usable()) return 0;
  lua_createtable(L, 0, 3);
  set_str(L, "shared", g_api->get_shared_data_dir());
  set_str(L, "user", g_api->get_user_data_dir());
  set_str(L, "sync", g_api->get_sync_dir());
  return 1;
}

static const luaL_Reg funcs[] = {
    {"start", l_start},
    {"redeploy", l_redeploy},
    {"sync", l_sync},
    {"select_schema", l_select_schema},
    {"poll", l_poll},
    {"ready", l_ready},
    {"shutdown", l_shutdown},
    {"version", l_version},
    {"process", l_process},
    {"select", l_select},
    {"highlight", l_highlight},
    {"change_page", l_change_page},
    {"delete", l_delete},
    {"clear", l_clear},
    {"commit", l_commit},
    {"context", l_context},
    {"status", l_status},
    {"get_option", l_get_option},
    {"set_option", l_set_option},
    {"schemas", l_schemas},
    {"dirs", l_dirs},
    {NULL, NULL},
};

EXPORT int luaopen_rime_core(lua_State *L) {
  if (!g_mx_ready) {
    mutex_init(&g_mx);
    mutex_init(&g_evmx);
    g_mx_ready = 1;
  }
  lua_newtable(L);
  luaL_register(L, NULL, funcs);
  return 1;
}
