#############################################################################
## Makefile.settings : Environment Variables for Makefile(s)
#include Makefile.settings
# … ⋮ ︙ • ● – — ™ ® © ± ° ¹ ² ³ ¼ ½ ¾ ÷ × ₽ € ¥ £ ¢ ¤ ♻ ⚐ ⚑ ✪ ❤  \ufe0f
# ☢ ☣ ☠ ¦ ¶ § † ‡ ß µ Ø ƒ Δ ☡ ☈ ☧ ☩ ✚ ☨ ☦ ☓ ♰ ♱ ✖  ☘  웃 𝐀𝐏𝐏 🡸 🡺 ➔
# ℹ️ ⚠️ ✅ ⌛ 🚀 🚧 🛠️ 🔧 🔍 🧪 👈 ⚡ ❌ 💡 🔒 📊 📈 🧩 📦 🥇 ✨️ 🔚
##############################################################################
## Environment variable rules:
## - Any TRAILING whitespace KILLS its variable value and may break recipes.
## - ESCAPE only that required by the shell (bash).
## - Environment hierarchy:
##   - Makefile environment OVERRIDEs OS environment lest set using `?=`.
##  	 - `FOO ?= bar` is overridden by parent setting; `export FOO=new`.
##  	 - `FOO :=`bar` is NOT overridden by parent setting.
##   - Docker YAML `env_file:` OVERRIDEs OS and Makefile environments.
##   - Docker YAML `environment:` OVERRIDEs YAML `env_file:`.
##   - CMD-inline OVERRIDEs ALL REGARDLESS; `make recipeX FOO=new BAR=new2`.


##############################################################################
## $(INFO) : USAGE : `$(INFO) "Any !"` in recipe prints quoted str, stylized.
SHELL   := /bin/bash
YELLOW  := "\e[1;33m"
RESTORE := "\e[0m"
INFO    := @bash -c 'printf $(YELLOW);echo "$$1";printf $(RESTORE)' MESSAGE


##############################################################################
## Project Meta

export PRJ_ROOT := $(shell pwd)
export PRJ_GIT  := $(shell git config remote.origin.url)
export LOG_PRE  := make
export UTC      := $(shell date '+%Y-%m-%dT%H.%M.%Z')

##############################################################################
## PVE

export PVE_CIDR     := 192.168.28.0/24
export PVE_K0S_CIDR := 10.0.33.0/24

##############################################################################
## Admin

## Public-key string of ssh user must be in ~/.ssh/authorized_keys of ADMIN_USER at all targets.
#export ADMIN_USER            ?= $(shell id -un)
export ADMIN_USER            ?= root
export ADMIN_KEY             ?= ${HOME}/.ssh/proxmox
export ADMIN_HOST            ?= pve
export ADMIN_TARGET_LIST     ?= ${ADMIN_HOST}
export ADMIN_SRC_DIR         ?= $(shell pwd)
#export ADMIN_DST_DIR         ?= ${ADMIN_SRC_DIR}
export ADMIN_DST_DIR         ?= /tmp/$(shell basename "${ADMIN_SRC_DIR}")

export ADMIN_JOURNAL_SINCE   ?= 15 minute ago

export ANSIBASH_TARGET_LIST  ?= ${ADMIN_TARGET_LIST}
export ANSIBASH_USER         ?= ${ADMIN_USER}


##############################################################################
## Recipes : Meta

menu :
	$(INFO) '🧩  Proxmox Virtual Environment'
	$(INFO) "🔍  Infra"
	@echo "creds        : Get PVE logon credentials"
	@echo "push         : Push to root@pve"
	@echo "pull         : Pull from root@pve"
	@echo "scan         : nmap -sn ${PVE_CIDR}"
	@echo "psrss        : Top RSS usage"
	@echo "pscpu        : Top CPU usage"
	$(INFO) "🛠️  Meta"
	@echo "userrc       : Install onto targets the latest shell scripts of github.com/sempernow/userrc.git"
	@echo "env          : Print the make environment"
	@echo "mode         : Fix folder and file modes of this project"
	@echo "eol          : Fix line endings : Convert all CRLF to LF"
	@echo "html         : Process all markdown (MD) to HTML"
	@echo "commit       : Commit and push this source"

env :
	$(INFO) 'Environment'
	@echo "PWD=${PRJ_ROOT}"
	@env |grep PVE_ |sort
	@echo
	@env |grep ADMIN_ |sort
	@echo
	@env |grep ANSIBASH_ |sort

eol :
	find . -type f ! -path '*/.git/*' -exec dos2unix {} \+
mode :
	find . -type d ! -path './.git/*' -exec chmod 0755 "{}" \;
	find . -type f ! -path './.git/*' -exec chmod 0640 "{}" \;
tree :
	tree -d |tee tree-d
html :
	bash make.proxmox.sh html
commit : html mode
	gc && git push && gl && gs
bundle :
	bash make.proxmox.sh bundle


##############################################################################
## Recipes : Host

scan :
	sudo nmap -sn ${PVE_CIDR} |tee logs/scan.nmap.log

push :
	bash make.proxmox.sh push

pull :
	bash make.proxmox.sh pull

psrss :
	ansibash psrss
pscpu :
	ansibash pscpu
userrc :
	ansibash 'git clone https://github.com/sempernow/userrc 2>/dev/null || echo ok'
	ansibash 'pushd userrc && git pull && make sync-user && make user'

