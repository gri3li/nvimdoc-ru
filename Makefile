# Файл перевода передаётся позиционно и строго с расширением .rux:
#   make new usr_02.rux
#   make check change.rux usr_02.rux   (check принимает несколько или ни одного)
#
# Переменные:
#   NVIM=<команда>    какой Neovim использовать (по умолчанию nvim из PATH);
#                     его справка и будет оригиналом для сверки
#   RUNTIME=<путь>    другая системная справка (каталог runtime или его doc/);
#                     по умолчанию $VIMRUNTIME, который сообщает сам NVIM

NVIM    ?= nvim
ROOT    := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

# Спрашиваем у NVIM, где его runtime (--clean: без пользовательского конфига).
ifeq ($(origin RUNTIME),undefined)
RUNTIME := $(or $(HELPDOC_RUNTIME),$(shell $(NVIM) --clean --headless --cmd 'lua io.stdout:write(vim.env.VIMRUNTIME)' --cmd 'qa!' 2>/dev/null))
endif

HELPDOC  = $(NVIM) -l $(ROOT)scripts/helpdoc.lua $(if $(RUNTIME),--runtime $(RUNTIME))

# Цели, которые принимают имена файлов: всё после цели — это файлы, а не цели.
FILE_GOALS := new check diff accept
ifneq ($(filter $(firstword $(MAKECMDGOALS)),$(FILE_GOALS)),)
FILES := $(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))
ifneq ($(filter-out %.rux,$(FILES)),)
$(error нужно имя файла перевода с расширением .rux, например change.rux; получено: $(filter-out %.rux,$(FILES)))
endif
# Чтобы make не пытался собирать change.rux как цель.
$(eval $(FILES):;@:)
endif

one-file = $(if $(filter 1,$(words $(FILES))),,$(error укажите один файл: make $@ <имя>.rux, например make $@ usr_02.rux))

.DEFAULT_GOAL := help

##@ Общее

.PHONY: help
help: ## Показать эту справку
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m [<имя>.rux ...] [NVIM=<команда>]\n\nСправка: $(or $(RUNTIME),не найдена — проверьте NVIM=$(NVIM))\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

.PHONY: status
status: ## Сводка по всем переводам: теги, предупреждения, изменился ли оригинал
	@$(HELPDOC) status

##@ Перевод

.PHONY: new
new: ## <имя>.rux — начать перевод: исходник в source/doc/, перевод в doc/
	$(one-file)
	@$(HELPDOC) new $(FILES)

.PHONY: check
check: ## [<имя>.rux ...] — проверить переводы против эталона (без имён — все)
	@$(HELPDOC) check $(FILES)

.PHONY: tags
tags: ## Пересоздать doc/tags-ru
	@$(HELPDOC) tags

.PHONY: readme
readme: ## Пересобрать таблицу «Что переведено» в README.md
	@$(HELPDOC) readme

##@ Обновление Neovim

.PHONY: diff
diff: ## <имя>.rux — что изменилось в оригинале с момента перевода
	$(one-file)
	@$(HELPDOC) diff $(FILES)

.PHONY: accept
accept: ## <имя>.rux — сделать текущий оригинал новым эталоном
	$(one-file)
	@$(HELPDOC) accept $(FILES)
