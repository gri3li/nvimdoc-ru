-- Инструмент для русских переводов справки Neovim.
--
-- Запуск из любого места:
--   nvim -l scripts/helpdoc.lua [--runtime <путь>] <команда> [имя ...]
--
-- Команды:
--   status            сводка по всем переводам: теги, ширина строк, изменился ли оригинал
--   new <имя>         начать перевод: скопировать оригинал в source/doc/ и doc/<имя>.rux
--   check [имя ...]   проверить перевод(ы) против оригинала (по умолчанию все)
--   diff <имя>        что изменилось в оригинале с момента перевода (diff -u)
--   accept <имя>      принять новую версию оригинала после обновления перевода
--   readme            пересобрать таблицу «Что переведено» в README.md
--   tags              пересоздать doc/tags-ru
--
-- <имя> можно писать как "change", "change.txt" или "change.rux".
--
-- Откуда брать системную (английскую) справку:
--   --runtime <путь>   каталог runtime Neovim или его doc/, например
--                      /opt/homebrew/Cellar/neovim/0.12.2/share/nvim/runtime
--   $HELPDOC_RUNTIME   то же через переменную окружения
--   по умолчанию       $VIMRUNTIME/doc того nvim, которым запущен скрипт
--
-- Устройство:
--   source/doc/<имя>.txt   английский оригинал, с которого сделан перевод (эталон);
--                          есть только у переведённых файлов
--   doc/<имя>.rux          перевод; Neovim находит его через 'helplang' = ru
--   doc/tags-ru            индекс тегов, генерируется (:helptags), в git не нужен
--   scripts/catalog.lua    разделы и темы всех файлов справки для README

local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2))))
local SRC = root .. "/source/doc"
local DOC = root .. "/doc"
local RUNTIME_DOC -- задаётся при разборе аргументов, см. resolve_runtime()
local RUNTIME_VERSION
local MAX_WIDTH = 78

local function nvim_version()
  local v = vim.version()
  return string.format("%d.%d.%d", v.major, v.minor, v.patch)
end

local function out(fmt, ...)
  io.stdout:write(string.format(fmt, ...) .. "\n")
end

local function die(fmt, ...)
  io.stderr:write("ошибка: " .. string.format(fmt, ...) .. "\n")
  os.exit(1)
end

local function exists(path)
  return vim.uv.fs_stat(path) ~= nil
end

local function read_lines(path)
  local f = assert(io.open(path, "r"))
  local lines = {}
  for line in f:lines() do
    lines[#lines + 1] = line
  end
  f:close()
  return lines
end

local function copy(from, to)
  vim.fn.mkdir(vim.fs.dirname(to), "p")
  assert(vim.uv.fs_copyfile(from, to))
end

local function name_of(arg)
  if not arg then
    die("не указано имя файла справки")
  end
  return (arg:gsub("%.txt$", ""):gsub("%.rux$", ""))
end

local function translated_names()
  local names = {}
  for name, kind in vim.fs.dir(DOC) do
    if kind == "file" and name:match("%.rux$") then
      names[#names + 1] = name:gsub("%.rux$", "")
    end
  end
  table.sort(names)
  return names
end

-- Разбор справки ------------------------------------------------------------

-- Теги: *тег*, перед которым начало строки или пробел, а после — пробел или
-- конец строки (так же их ищет :helptags).
local function collect_tags(lines)
  local tags, order = {}, {}
  for lnum, line in ipairs(lines) do
    for s, tag, e in line:gmatch("()%*([^%s%*|]+)%*()") do
      local before = s == 1 and " " or line:sub(s - 1, s - 1)
      local after = line:sub(e, e)
      if before:match("%s") and (after == "" or after:match("%s")) then
        if not tags[tag] then
          order[#order + 1] = tag
        end
        tags[tag] = tags[tag] or lnum
      end
    end
  end
  return tags, order
end

-- Ссылки: |ссылка|
local function collect_links(lines)
  local links = {}
  for _, line in ipairs(lines) do
    for link in line:gmatch("|([^%s|]+)|") do
      links[link] = (links[link] or 0) + 1
    end
  end
  return links
end

local function long_lines(lines)
  local res = {}
  for lnum, line in ipairs(lines) do
    local w = vim.fn.strdisplaywidth(line)
    if w > MAX_WIDTH then
      res[#res + 1] = { lnum = lnum, width = w }
    end
  end
  return res
end

-- Проверка одного перевода -------------------------------------------------

local function check(name, verbose)
  local src_path = SRC .. "/" .. name .. ".txt"
  local rux_path = DOC .. "/" .. name .. ".rux"
  local res = { name = name, errors = 0, warnings = 0 }

  if not exists(rux_path) then
    die("нет перевода %s", rux_path)
  end
  if not exists(src_path) then
    die("нет оригинала %s (выполните: make new %s.rux)", src_path, name)
  end

  local src, rux = read_lines(src_path), read_lines(rux_path)

  local function err(fmt, ...)
    res.errors = res.errors + 1
    if verbose then
      out("  ОШИБКА  " .. fmt, ...)
    end
  end
  local function warn(fmt, ...)
    res.warnings = res.warnings + 1
    if verbose then
      out("  предупр " .. fmt, ...)
    end
  end

  -- 1. Первая строка должна объявлять тот же тег файла (*change.txt*).
  local first = src[1]:match("^%*([^*]+)%*")
  if not (rux[1] or ""):match("^%*" .. vim.pesc(first or "") .. "%*") then
    err("первая строка должна начинаться с *%s*", first or "?")
  end

  -- 2. Набор тегов должен совпадать: иначе :help по тегу не найдёт перевод
  --    или найдёт тег, которого нет в оригинале.
  local st, st_order = collect_tags(src)
  local rt, rt_order = collect_tags(rux)
  for _, tag in ipairs(st_order) do
    if not rt[tag] then
      err("пропал тег *%s* (оригинал, строка %d)", tag, st[tag])
    end
  end
  for _, tag in ipairs(rt_order) do
    if not st[tag] then
      err("лишний тег *%s* (перевод, строка %d)", tag, rt[tag])
    end
  end
  res.tags = #st_order

  -- 3. Ссылки: пропавшая ссылка — повод проверить, не потерялся ли кусок.
  local sl, rl = collect_links(src), collect_links(rux)
  local missing = {}
  for link in pairs(sl) do
    if not rl[link] then
      missing[#missing + 1] = link
    end
  end
  table.sort(missing)
  for _, link in ipairs(missing) do
    warn("нет ссылки |%s|", link)
  end
  for link in pairs(rl) do
    if not sl[link] then
      warn("новая ссылка |%s| (нет в оригинале)", link)
    end
  end

  -- 4. Модлайн в конце (tw/ts/ft=help) должен сохраниться.
  local function modeline(lines)
    for i = #lines, math.max(1, #lines - 3), -1 do
      if lines[i]:match("vim:.*ft=help") then
        return lines[i]
      end
    end
  end
  local sm, rm = modeline(src), modeline(rux)
  if sm and sm ~= rm then
    err("модлайн в конце файла должен быть: %s", sm)
  end

  -- 5. Ширина строк: только предупреждение (в оригинале тоже бывают длинные).
  local src_long = {}
  for _, l in ipairs(long_lines(src)) do
    src_long[src[l.lnum]] = true
  end
  for _, l in ipairs(long_lines(rux)) do
    if not src_long[rux[l.lnum]] then
      warn("строка %d шире %d колонок (%d)", l.lnum, MAX_WIDTH, l.width)
    end
  end

  -- 6. Совпадает ли эталон с текущим runtime.
  local upstream = RUNTIME_DOC .. "/" .. name .. ".txt"
  if not exists(upstream) then
    res.upstream = "нет в runtime"
  elseif vim.fn.readblob(upstream) == vim.fn.readblob(src_path) then
    res.upstream = "актуален"
  else
    res.upstream = "ИЗМЕНИЛСЯ"
  end

  return res
end

-- Команды -------------------------------------------------------------------

local cmd = {}

function cmd.status()
  local names = translated_names()
  if #names == 0 then
    out("Переводов пока нет. Начать: make new <имя>.rux")
    return
  end
  -- Выравнивание по ширине на экране, а не в байтах (кириллица — 2 байта).
  local function pad(s, w, right)
    local fill = (" "):rep(math.max(0, w - vim.fn.strdisplaywidth(tostring(s))))
    return right and fill .. s or s .. fill
  end
  local function row(a, b, c, d, e)
    out("%s %s %s %s  %s", pad(a, 16), pad(b, 6, true), pad(c, 7, true), pad(d, 8, true), e)
  end
  out("Справка Nvim %s: %s", RUNTIME_VERSION, RUNTIME_DOC)
  row("файл", "тегов", "ошибок", "предупр.", "оригинал")
  for _, name in ipairs(names) do
    local r = check(name, false)
    row(name, r.tags, r.errors, r.warnings, r.upstream)
  end
end

function cmd.check(...)
  local names = { ... }
  if #names == 0 then
    names = translated_names()
  end
  local failed = false
  for _, arg in ipairs(names) do
    local name = name_of(arg)
    out("%s.rux", name)
    local r = check(name, true)
    out("  итог: тегов %d, ошибок %d, предупреждений %d, оригинал %s",
      r.tags, r.errors, r.warnings, r.upstream)
    failed = failed or r.errors > 0
  end
  if failed then
    os.exit(1)
  end
end

function cmd.new(arg)
  local name = name_of(arg)
  local upstream = RUNTIME_DOC .. "/" .. name .. ".txt"
  local src_path = SRC .. "/" .. name .. ".txt"
  local rux_path = DOC .. "/" .. name .. ".rux"
  if not exists(upstream) then
    die("нет файла %s", upstream)
  end
  if exists(rux_path) then
    die("перевод уже есть: %s", rux_path)
  end
  copy(upstream, src_path)
  copy(upstream, rux_path)
  out("Оригинал: %s", src_path)
  out("Перевод:  %s  (пока копия оригинала — переводите текст, теги не трогайте)", rux_path)
  out("После перевода: make check %s.rux && make tags", name)
end

function cmd.diff(arg)
  local name = name_of(arg)
  local res = vim.system({
    "diff", "-u",
    "--label", "source/doc/" .. name .. ".txt (переведено)",
    "--label", "runtime/doc/" .. name .. ".txt (Nvim " .. RUNTIME_VERSION .. ")",
    SRC .. "/" .. name .. ".txt",
    RUNTIME_DOC .. "/" .. name .. ".txt",
  }, { text = true }):wait()
  if res.code == 0 then
    out("Оригинал не менялся.")
  else
    io.stdout:write(res.stdout)
  end
end

function cmd.accept(arg)
  local name = name_of(arg)
  copy(RUNTIME_DOC .. "/" .. name .. ".txt", SRC .. "/" .. name .. ".txt")
  out("Эталон %s обновлён до Nvim %s.", name, RUNTIME_VERSION)
  cmd.check(name)
end

local function runtime_files()
  local files = {}
  for name, kind in vim.fs.dir(RUNTIME_DOC) do
    if kind == "file" and name:match("%.txt$") then
      files[#files + 1] = name
    end
  end
  table.sort(files)
  return files
end

function cmd.readme()
  local readme_path = root .. "/README.md"
  local BEGIN, END = "<!-- files:begin -->", "<!-- files:end -->"
  local text = table.concat(read_lines(readme_path), "\n")
  local s, e = text:find(BEGIN, 1, true), select(2, text:find(END, 1, true))
  if not s or not e then
    die("в README.md нет меток %s и %s", BEGIN, END)
  end

  local catalog = dofile(root .. "/scripts/catalog.lua")
  local known = {}
  for _, section in ipairs(catalog) do
    for _, item in ipairs(section[2]) do
      known[item[1]] = true
    end
  end

  -- Всё, что есть в системной справке, но не описано в каталоге, — в «Прочее».
  local in_runtime, other = {}, {}
  for _, file in ipairs(runtime_files()) do
    in_runtime[file] = true
    if not known[file] then
      other[#other + 1] = { file, "" }
    end
  end
  if #other > 0 then
    catalog[#catalog + 1] = { "Прочее", other }
  end

  local function state(file)
    local name = file:gsub("%.txt$", "")
    if not exists(DOC .. "/" .. name .. ".rux") then
      return nil
    end
    local upstream = RUNTIME_DOC .. "/" .. file
    if exists(upstream) and vim.fn.readblob(upstream) ~= vim.fn.readblob(SRC .. "/" .. file) then
      return "⚠️ устарел"
    end
    return "✅ переведён"
  end

  local total, done = 0, 0
  local body, missing = {}, {}
  for _, section in ipairs(catalog) do
    local rows, n, d = {}, 0, 0
    for _, item in ipairs(section[2]) do
      local file, topic = item[1], item[2]
      local translated = exists(DOC .. "/" .. file:gsub("%.txt$", ".rux"))
      if not in_runtime[file] and not translated then
        missing[#missing + 1] = file
      else
        local st = state(file)
        n, d = n + 1, d + (st and 1 or 0)
        rows[#rows + 1] = string.format("| `%s` | %s | %s |", file, topic, st or "—")
      end
    end
    if n > 0 then
      total, done = total + n, done + d
      vim.list_extend(body, {
        "",
        string.format("<details><summary><b>%s</b> — %d из %d</summary>", section[1], d, n),
        "",
        "| Файл | Тема | Статус |",
        "|---|---|---|",
      })
      vim.list_extend(body, rows)
      vim.list_extend(body, { "", "</details>" })
    end
  end

  local head = string.format("Справка Nvim %s: переведено **%d из %d** файлов.", RUNTIME_VERSION, done, total)
  local block = BEGIN .. "\n" .. head .. "\n" .. table.concat(body, "\n") .. "\n" .. END
  text = text:sub(1, s - 1) .. block .. text:sub(e + 1)

  local f = assert(io.open(readme_path, "w"))
  f:write(text, text:sub(-1) == "\n" and "" or "\n")
  f:close()
  out("README.md: переведено %d из %d.", done, total)
  for _, item in ipairs(other) do
    out("  нет в scripts/catalog.lua: %s", item[1])
  end
  for _, file in ipairs(missing) do
    out("  нет в системной справке (удалён из Nvim?): %s", file)
  end
end

function cmd.tags()
  vim.cmd.helptags(vim.fn.fnameescape(DOC))
  out("Обновлён %s/tags-ru", DOC)
end

-- Системная справка: --runtime <путь>, $HELPDOC_RUNTIME или $VIMRUNTIME.
local function resolve_runtime(path)
  if not path or path == "" then
    return vim.env.VIMRUNTIME .. "/doc", nvim_version()
  end
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p")):gsub("/$", "")
  local doc
  if exists(path .. "/doc/help.txt") then
    doc = path .. "/doc"
  elseif exists(path .. "/help.txt") then
    doc = path
  else
    die("в %s нет справки Neovim (ожидается каталог runtime или его doc/ с help.txt)", path)
  end
  -- Справка того же nvim, которым запущен скрипт, — версия известна точно.
  local own = vim.uv.fs_realpath(vim.env.VIMRUNTIME .. "/doc")
  if own and vim.uv.fs_realpath(doc) == own then
    return doc, nvim_version()
  end
  -- Иначе берём версию из пути (…/neovim/0.12.2/…), если она там есть.
  return doc, doc:match("/v?(%d+%.%d+%.%d+)/") or "?"
end

local args, runtime = {}, vim.env.HELPDOC_RUNTIME
local i, argv = 1, _G.arg or {}
while i <= #argv do
  local a = argv[i]
  if a == "--runtime" then
    runtime, i = argv[i + 1] or die("после --runtime нужен путь"), i + 2
  elseif a:match("^%-%-runtime=") then
    runtime, i = a:sub(#"--runtime=" + 1), i + 1
  else
    args[#args + 1], i = a, i + 1
  end
end
RUNTIME_DOC, RUNTIME_VERSION = resolve_runtime(runtime)

local name = args[1] or "status"
if not cmd[name] then
  die("неизвестная команда %q (status, new, check, diff, accept, readme, tags)", name)
end
cmd[name](unpack(args, 2))
