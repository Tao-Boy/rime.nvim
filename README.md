# rime.nvim

在 Neovim 里直接使用 [Rime 中州韵输入法](https://rime.im)。插件通过一个原生 Lua C 模块调用 librime，不依赖系统输入法，也不需要额外的语言服务器进程。

- **原生模块，编译零依赖**：C 模块在运行时 `dlopen` 加载 librime，Lua 与 librime 的头文件已随仓库提供，编译只需要 C 编译器和 `make`，不需要 `librime-dev` 或 LuaJIT 开发包。
- **异步，不卡编辑器**：加载 librime、部署（编译词典）、同步用户词典、切换方案都在后台线程完成；按键处理是同步的，但只需约 0.1 ms（含 Rime 处理、取上下文和绘制预编辑），候选菜单每个事件循环只重绘一次。
- **探针自动切换中英文**：根据光标所在环境（代码/注释/字符串、代码块、数学公式、英文单词之后……）决定按键直接输入英文还是交给 Rime，可以写自己的探针函数。
- **两种候选菜单**：Neovim 原生补全菜单（`ins-completion-menu`），或 [blink.cmp](https://github.com/saghen/blink.cmp)。
- **预编辑行内显示**：拼音以虚拟文本显示在光标处，不写入缓冲区，不污染 undo，也不会触发 LSP / tree-sitter 的变更。上屏的文字与手动键入完全一样插入：undo、`.` 重复、缩写都正常。
- **与其他插件共存**：被覆盖的插入模式映射（autopairs、blink.cmp、`<Plug>` 映射……）在按键不交给 Rime 时照常执行，关闭输入法时恢复。
- **支持 librime-lua**：可直接使用 [rime-ice（雾凇拼音）](https://github.com/iDvel/rime-ice) 等依赖 Lua 插件的配置。
- **支持 `vim.pack`**：首次使用时自动编译，更新后自动重新编译。

## 依赖

- Neovim ≥ 0.11（用 `vim.pack` 安装需要 0.12）
- librime 运行库（建议 ≥ 1.8）以及 Rime 数据（输入方案、词典）
- C 编译器与 `make`

| 系统 | 安装 |
| --- | --- |
| Debian / Ubuntu | `sudo apt install librime1t64 rime-data-luna-pinyin build-essential`（旧版本为 `librime1`；用 rime-ice 另装 `librime-plugin-lua`） |
| Arch Linux | `sudo pacman -S librime rime-luna-pinyin base-devel` |
| macOS | 安装[鼠须管](https://rime.im/download/)（插件会使用它自带的 librime 与数据），或 `brew install librime` 并自备数据 |
| NixOS / Nix | 见下文 [NixOS](#nixos) |

也可以不装系统的 Rime 数据，把 rime-ice 等完整配置放进用户目录（见下文 `user_data_dir`）。

## 安装

### vim.pack（Neovim 0.12+）

```lua
vim.pack.add({ 'https://github.com/Tao-Boy/rime.nvim' })

require('rime').setup({
  schema = 'luna_pinyin_simp',
  probes = { 'code', 'code_block', 'math', 'tex_command', 'after_ascii', 'uppercase' },
})

vim.keymap.set({ 'n', 'i' }, '<C-\\>', '<Plug>(rime-toggle)')
```

第一次进入插入模式（或 `preload = true` 时启动后）插件会在后台执行 `make` 编译 `lib/rime_core.so`，编译和首次部署期间按键照常输入英文，就绪后自动生效。插件更新后源文件比库新，下次启动会自动重新编译；也可以随时运行 `:Rime build`。

### NixOS

和在其他 Linux 上一样：系统里有 librime 与 Rime 数据，插件用 `make` 正常编译（需要 `gcc`/`clang` 与 `make`）。插件不会调用 `nix-build`、`nix-shell` 等命令去下载或构建任何东西。

librime 和 rime-data 来自哪里都可以：

- `environment.systemPackages`、home-manager 的 `home.packages` 或 `nix profile` 安装的；
- fcitx5-rime、ibus-rime 带进 `/nix/store` 的那份；
- 编译时 `pkg-config` 能找到的 librime：编译时会记下它的路径。

查找顺序：

1. 配置中的 `librime`、`shared_data_dir`；
2. Nix profile：`/etc/profiles/per-user/$USER`、`~/.nix-profile`、`/run/current-system/sw` 等；
3. 常规的库名与目录；
4. 编译时 `pkg-config` 找到的 librime；
5. `/nix/store` 中版本最新的 librime 与 rime-data（只读扫描，在后台线程中进行）。

找不到时，报错会逐行列出每个尝试过的路径和失败原因。只存在于 `/nix/store`、没有被任何 profile 引用的 librime，可能会被 `nix-collect-garbage` 删掉。

nixpkgs 的 librime 已合入 librime-lua 插件，rime-ice 等配置可以直接放进 `user_data_dir` 使用。

在其他发行版上使用 Nix 时，Neovim 与 librime 要么都来自 Nix，要么都来自发行版：Nix 的 librime 依赖 Nix 的 glibc，无法加载进发行版的 Neovim。插件只在 NixOS 上、或 Neovim 本身来自 Nix 时，才优先使用 profile 中的 Nix librime。

### lazy.nvim

```lua
{
  'Tao-Boy/rime.nvim',
  build = 'make',
  opts = { schema = 'luna_pinyin_simp' },
  keys = { { '<C-\\>', '<Plug>(rime-toggle)', mode = { 'n', 'i' } } },
}
```

## 使用

用 `<Plug>(rime-toggle)`（上例绑定在 `<C-\>`）切换中文输入。打开后在插入模式中：

| 按键 | 作用（有输入中的编码时） |
| --- | --- |
| 字母 | 输入编码 |
| `<Space>` / `<C-y>` | 上屏高亮的候选 |
| 数字 | 选择对应候选 |
| `<CR>` | 上屏原始编码 |
| `<Esc>` / `<C-e>` | 清除编码（没有编码时 `<Esc>` 照常离开插入模式） |
| `<BS>` / `<C-h>` / `<Del>` | 删除编码 |
| `<Up>` `<Down>` / `<C-p>` `<C-n>` | 移动高亮 |
| `<PageUp>` `<PageDown>`，`-` `=`，`,` `.` | 翻页（取决于方案的 key_binder 设置） |
| `<Left>` `<Right>` `<Home>` `<End>` `<Tab>` | 在编码中移动 |

没有编码时这些特殊键保持原来的行为，标点按 Rime 的规则转换（`,` → `，`）。离开插入模式、切换缓冲区或光标被移走时，未完成的编码会被清除（见 `on_leave`）。

### 命令

| 命令 | 说明 |
| --- | --- |
| `:Rime toggle` / `enable` / `disable` | 开关中文输入 |
| `:Rime ascii` | 切换 Rime 自己的西文模式（相当于桌面输入法里按 Shift；终端里无法单独检测 Shift） |
| `:Rime schema [id]` | 切换输入方案，不带参数时弹出选择 |
| `:Rime deploy` | 重新部署（修改了 yaml 配置之后） |
| `:Rime sync` | 同步用户词典 |
| `:Rime build` | 重新编译原生模块 |
| `:Rime status` | 显示状态 |

`<Plug>(rime-toggle)` 与 `<Plug>(rime-ascii)` 在普通模式和插入模式都可用。`:checkhealth rime` 检查编译、librime、数据目录和运行状态。

## 探针

探针根据光标附近的内容决定一个按键是直接输入英文，还是交给 Rime。只在没有正在输入的编码时运行（编码中的按键总是交给 Rime），按顺序执行：

- 返回 `true`（或 `'ascii'`）：这个键直接输入英文；
- 返回 `'rime'`：交给 Rime，不再询问后面的探针；
- 返回 `nil` / `false`：交给下一个探针，都没有意见就交给 Rime。

内置探针（字符串名字）：

| 名字 | 何时输入英文 |
| --- | --- |
| `code` | 程序代码中，注释和字符串之外（tree-sitter 高亮，或 syntax）。字符串中的引号也按英文输入，以便闭合字符串 |
| `code_block` | Markdown 代码块、行内代码、注入了其他语言的区域 |
| `math` | TeX 数学环境：`$…$`、`\[…\]`、equation 等（vimtex、tree-sitter 或 syntax） |
| `tex_command` | TeX 命令及其参数名：`\alpha`、`\begin{…}` |
| `after_ascii` | 紧跟在英文字母（可再跟数字、标点）之后，便于连续输入英文单词 |
| `space_after_ascii` | 英文之后的空格之后 |
| `uppercase` | 输入的是大写字母 |
| `punct_after_ascii` | 在英文字符之后输入标点（`a,`、`1.` 保持英文标点） |
| `line_start` | 行首（只有空白在光标前） |

`code` 在 `prose_filetypes`（markdown、text、tex、gitcommit……）中不起作用。

自定义探针是一个函数，参数是光标处的上下文：

```lua
require('rime').setup({
  probes = {
    'code',
    -- 在 # 之后总是输入中文
    function(ctx)
      if ctx.before:find('#%s*$') then return 'rime' end
    end,
    -- 在 Telescope 等提示符里输入英文
    function(ctx)
      return vim.bo[ctx.buf].buftype == 'prompt'
    end,
    'after_ascii',
  },
})
```

| 字段 | 内容 |
| --- | --- |
| `buf`、`win` | 当前缓冲区、窗口 |
| `row`、`col` | 光标位置（0 起，`col` 为字节列） |
| `line`、`before` | 当前行，光标前的文本 |
| `key` | 正在输入的字符；只查询模式时为 `nil` |
| `filetype` | 文件类型 |
| `ctx:captures()` | 光标处的 tree-sitter 高亮捕获名（没有 tree-sitter 高亮时为 `nil`） |
| `ctx:syntax()` | 光标处的 syntax 组名 |

探针每次按键大约耗时 5–130 µs（在 1500 行的 Lua 文件里测得，包括按需增量解析 tree-sitter），出错的探针会报告一次并被跳过，不会影响输入。

## 候选菜单

### 原生补全菜单（默认）

`ui = 'native'`。候选显示在 Neovim 的补全菜单中，第一项后面显示页码（有下一页时带 `+`）。菜单项的格式可以用 `native.format` 修改。

### blink.cmp

```lua
require('rime').setup({ ui = 'blink' })
```

插件会自动向 blink.cmp 注册名为 `rime` 的 source（`blink.provider`），输入编码时只显示 Rime 的候选，不需要把它加到 `sources.default`。候选的序号显示在图标位置，注释显示在右侧。

blink.cmp 自己的按键也能用：用它的键移动选择后，按 `<Space>` 上屏的就是菜单中选中的候选；用 blink 的接受键（如 `<C-y>`、`select_and_accept`）接受候选时，由 Rime 完成上屏并记录词频。支持 blink.cmp 1.x 与 main 分支。

想自定义 source（如改名字）时，自己在 blink 里声明同名 provider 即可：

```lua
sources = { providers = { rime = { name = 'Rime', module = 'rime.blink' } } }
```

## 配置

默认值：

```lua
require('rime').setup({
  shared_data_dir = nil,  -- 共享数据目录；nil 自动查找 /usr/share/rime-data、Nix profile、Homebrew、鼠须管……
  user_data_dir = vim.fn.stdpath('data') .. '/rime',  -- 用户目录：custom.yaml、用户词典、build/
  log_dir = vim.fn.stdpath('log') .. '/rime',
  log_level = 'error',    -- 'info' | 'warning' | 'error' | 'fatal'
  librime = nil,          -- librime 动态库路径；nil 自动查找（Nix 见上文）
  schema = nil,           -- 启动后选择的方案；nil 用 Rime 自己的选择
  full_check = false,     -- 启动部署时检查所有文件
  preload = true,         -- 界面启动后就在后台启动 Rime（无界面的实例不启动）
  auto_build = true,      -- 缺少或过期时自动 make

  enabled = false,        -- 启动时就打开中文输入
  filter = function(buf) return vim.bo[buf].buftype ~= 'terminal' end,
  probes = {},
  prose_filetypes = { '', 'text', 'markdown', 'org', 'norg', 'neorg', 'tex', 'plaintex', 'latex',
    'typst', 'rst', 'asciidoc', 'gitcommit', 'mail', 'help', 'quarto', 'rmd' },
  -- 有编码时交给 Rime 的特殊键：{ [Vim 键] = 'Rime 键名' }，设为 false 不映射
  keys = {
    ['<Space>'] = 'space', ['<BS>'] = 'BackSpace', ['<C-h>'] = 'BackSpace', ['<Del>'] = 'Delete',
    ['<CR>'] = 'Return', ['<S-CR>'] = 'Shift+Return', ['<Esc>'] = 'Escape', ['<C-e>'] = 'Escape',
    ['<C-y>'] = 'space', ['<Tab>'] = 'Tab', ['<S-Tab>'] = 'Shift+ISO_Left_Tab',
    ['<Left>'] = 'Left', ['<Right>'] = 'Right', ['<Up>'] = 'Up', ['<Down>'] = 'Down',
    ['<C-p>'] = 'Up', ['<C-n>'] = 'Down', ['<PageUp>'] = 'Page_Up', ['<PageDown>'] = 'Page_Down',
    ['<Home>'] = 'Home', ['<End>'] = 'End',
  },
  nowait = true,          -- 映射加 <nowait>，以 jk 之类开头的映射不会让字母等待超时
  on_leave = 'clear',     -- 离开插入模式时：'clear' 丢弃编码，'commit' 上屏原始编码

  ui = 'native',          -- 'native' | 'blink'
  preedit = 'preedit',    -- 行内显示：'preedit'（ni hao）| 'input'（nihao）| 'preview'（你好）| false
  native = {
    format = function(label, cand) return label .. '. ' .. cand.text end,
  },
  blink = { provider = 'rime' },
  status = { off = '', loading = '…', zh = '中', en = 'EN', ascii = 'A' },
  mode_events = false,    -- 光标移动时重新计算模式并触发 User RimeModeChanged
})
```

Rime 键名可以带修饰键，如 `'Shift+Tab'`、`'Control+Return'`。

### Rime 配置

所有 Rime 配置都放在 `user_data_dir`（默认 `~/.local/share/nvim/rime`）中，与桌面输入法分开：fcitx5、ibus 运行时会锁住它们的用户词典。可以把 rime-ice 等配置整个复制进来，或者写 `default.custom.yaml`、`<方案>.custom.yaml`，改完运行 `:Rime deploy`。

同一个用户目录同一时间只能被一个进程完整使用：同时打开第二个 Neovim 时，后者打不开（被锁住的）用户词典，仍可输入，但不会记录词频。

### 状态栏与事件

```lua
-- lualine
sections = { lualine_x = { function() return require('rime').status() end } }
```

`require('rime').mode()` 返回 `'off'`、`'loading'`、`'ascii'`、`'en'`（探针判定当前位置输入英文）或 `'zh'`，结果按缓冲区状态与光标位置缓存，可以放心在状态栏中调用。

模式变化时触发 `User RimeModeChanged`（`data.mode`、`data.previous`）；打开 `mode_events` 后光标移动引起的变化（如进出注释）也会触发，例如用来改变光标颜色：

```lua
vim.api.nvim_create_autocmd('User', {
  pattern = 'RimeModeChanged',
  callback = function(ev)
    vim.api.nvim_set_hl(0, 'Cursor', { bg = ev.data.mode == 'zh' and '#e5a50a' or '#aaaaaa' })
  end,
})
```

另有 `User RimeReady`（Rime 就绪）与 `User RimeOption`（方案或选项变化）。

高亮组：`RimePreedit`（预编辑，默认链接到 `Underlined`）、`RimeLabel`（blink 菜单中的序号）。

## Lua API

```lua
local rime = require('rime')
rime.setup(opts)
rime.enable() / rime.disable() / rime.toggle() / rime.is_enabled()
rime.toggle_ascii()
rime.mode() / rime.status()
rime.select_schema(id?) / rime.schemas()
rime.deploy() / rime.sync() / rime.build()
```

## 实现与性能

```
按键 ─▶ <expr> 映射 ─▶ 探针（未在输入时）─▶ rime_core.process()  ~0.1 ms，同步
                                              │
                    返回上屏文字，按键入方式插入 ◀┘
                    预编辑 extmark 立即更新
                    候选菜单 vim.schedule()，每个事件循环最多一次

后台线程：dlopen librime、RimeInitialize、部署、同步、切换方案
          Lua 通过一个只在任务进行时运行的 uv 定时器轮询结果
```

- 按键在插入模式的 buffer-local `<expr>` 映射里同步交给 Rime。Rime 处理一个键只要几十微秒，同步处理保证了按键和上屏文字的顺序，返回值作为键入的文字插入，所以 undo、`.` 重复、缩写、`textwidth` 自动换行都和普通输入一样。
- 耗时的操作（首次部署可能要数秒到数分钟）全部在 C 模块的工作线程中进行，期间按键直接输入英文，编辑器不会等待。会话建立后还会在后台先查询一次，把词典调入内存，避免第一个键变慢。
- 预编辑是行内虚拟文本，缓冲区内容在输入编码时不变，没有 TextChanged、LSP didChange、tree-sitter 重新解析的开销。
- 实测（本机，luna_pinyin）：每键约 0.1 ms，`setup()` 0.7 ms，带预编译数据时 Rime 在后台约 60 ms 就绪。
- Linux 上 Neovim 导出了 LuaJIT 的 `lua_*` 符号，librime-lua（Lua 5.4）会错误地绑定到它们而崩溃。C 模块用 `RTLD_DEEPBIND` 加载 librime 及其插件来避免这一点；librime 的 glog 日志只写入 `log_dir`，不会打到 stderr 弄乱界面。

## 局限

- 只支持插入/替换模式，还不支持命令行模式。
- 部署（首次使用或修改配置后编译词典）进行中退出 Neovim 时，会等待部署完成再退出：librime 无法中途取消部署。
- 在 Linux 上开发和测试（包括 nixpkgs 的 Neovim 与 librime）。macOS 的编译选项与库、数据路径已经处理，但未在真机上测试；Windows 未经测试：`Makefile` 有 MinGW 分支（链接 `lua51`），需要自行提供 librime 的 `rime.dll`。

## 开发

```sh
make        # 编译 lib/rime_core.so
make test   # 无界面测试，需要 librime 与 luna_pinyin 方案
```

## 许可

MIT。`src/lua/` 中的 Lua 头文件来自 LuaJIT（MIT），`src/rime/rime_api.h` 来自 librime（BSD-3-Clause），各自附有许可文件。
