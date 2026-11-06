-- nvimdoc-ru: русский перевод справки Neovim.
-- Переводы лежат в doc/*.rux этого плагина; :help находит их через 'helplang'.

if vim.g.loaded_nvimdoc_ru then
  return
end
vim.g.loaded_nvimdoc_ru = true

-- Сначала ищем тег в русской справке, затем в английской.
-- Если пользователь уже задал 'helplang' с ru, не трогаем.
if not vim.tbl_contains(vim.opt.helplang:get(), "ru") then
  vim.opt.helplang:prepend("ru")
  if not vim.tbl_contains(vim.opt.helplang:get(), "en") then
    vim.opt.helplang:append("en")
  end
end

-- Встроенное определение типа файла считает справкой только */doc/*.txt,
-- поэтому без этого у .rux нет подсветки и оглавления (gO).
vim.filetype.add({
  pattern = { [".*/doc/.*%.rux"] = "help" },
})

-- Пересоздаём doc/tags-ru, если какой-то перевод новее индекса
-- (менеджер плагинов может этого не сделать, а при разработке — тем более).
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2))))
local doc = root .. "/doc"

local function mtime(path)
  local stat = vim.uv.fs_stat(path)
  return stat and stat.mtime.sec or 0
end

local newest = 0
for _, file in ipairs(vim.fn.glob(doc .. "/*.rux", false, true)) do
  newest = math.max(newest, mtime(file))
end

if newest > mtime(doc .. "/tags-ru") then
  pcall(vim.cmd.helptags, vim.fn.fnameescape(doc))
end
