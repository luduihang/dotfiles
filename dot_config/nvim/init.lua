-- 极简 nvim 配置: 像 classic vi 一样干净，但保留现代基础功能

-- ── 编辑行为 ──
vim.opt.number = true            -- 绝对行号
vim.opt.mouse = 'a'              -- 鼠标支持
vim.opt.clipboard = 'unnamedplus'-- 系统剪贴板
vim.opt.ignorecase = true        -- 搜索忽略大小写
vim.opt.smartcase = true         -- 有大写自动区分
vim.opt.tabstop = 4
vim.opt.shiftwidth = 4
vim.opt.expandtab = true         -- tab → 空格
vim.opt.autoindent = true
vim.opt.smartindent = true
vim.opt.hlsearch = false         -- 不高亮搜索结果
vim.opt.incsearch = true         -- 增量搜索
vim.opt.swapfile = false         -- 不产生 .swp 文件
vim.opt.undofile = true          -- 持久撤销
vim.opt.undodir = vim.fn.stdpath('data') .. '/undo'

-- ── 关掉所有视觉噪音 ──
vim.opt.showmode = false         -- 不显示 -- INSERT --
vim.opt.showcmd = false          -- 不显示命令
vim.opt.ruler = false            -- 不显示光标位置
vim.opt.laststatus = 0           -- 不显示状态栏
vim.opt.signcolumn = 'no'        -- 不显示符号列
vim.opt.cmdheight = 1            -- 命令行 1 行
vim.opt.termguicolors = true     -- 真彩色
vim.opt.background = 'dark'
