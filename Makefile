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
	$(INFO) "🔍  Inspect"
	@echo "ausearch     : SELinux : ausearch -m AVC,... -ts recent"
	@echo "sealert      : SELinux : sealert -l '*'"
	@echo "net          : Interfaces' info"
	@echo "ruleset      : nftables rulesets"
	@echo "iptables     : iptables"
	@echo "psrss        : Top RSS usage"
	@echo "pscpu        : Top CPU usage"
	@echo "scan         : Nmap scan report"
	$(INFO) "⚠️  Teardown"
	$(INFO) "🛠️  Maintenance"
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
	find . -type f ! -path './.git/*' -name '*.md' -exec md2html.exe "{}" \;
commit : html mode
	gc && git push && gl && gs


##############################################################################
## Recipes : Host

scan :
	@echo 🔍 ${PVE_CIDR} |tee ${ADMIN_SRC_DIR}/logs/${LOG_PRE}.scan.nmap.pve.log
	ansibash nmap -sn ${PVE_CIDR} |tee -a ${ADMIN_SRC_DIR}/logs/${LOG_PRE}.scan.nmap.pve.log
	@echo 🔍 ${PVE_K0S_CIDR} |tee ${ADMIN_SRC_DIR}/logs/${LOG_PRE}.scan.nmap.k0s.log
	ansibash nmap -sn ${PVE_K0S_CIDR} |tee -a ${ADMIN_SRC_DIR}/logs/${LOG_PRE}.scan.nmap.k0s.log
status :
	@ansibash 'printf "%12s: %s\n" Host $$(hostname) \
	    && printf "%12s: %s\n" User $$(id -un) \
	    && printf "%12s: %s\n" Kernel $$(uname -r) \
	    && printf "%12s: %s\n" firewalld $$(systemctl is-active firewalld.service) \
	    && printf "%12s: %s\n" SELinux $$(getenforce) \
	    && printf "%12s: %s\n" uptime "$$(uptime)" \
	  '
ausearch :
	ansibash sudo ausearch -m AVC,USER_AVC,SELINUX_ERR,USER_SELINUX_ERR -ts recent \
	  |tee ${ADMIN_SRC_DIR}/logs/${LOG_PRE}.ausearch.${UTC}.log
sealert :
	ansibash 'sudo sealert -l "*" |grep -e == -e "Source Path" -e "Last" |tail -n 20'
net :
	ansibash 'sudo nmcli dev status'
ruleset :
	ansibash sudo nft list ruleset
iptables :
	ansibash sudo iptables -L -n -v
psrss :
	ansibash psrss
pscpu :
	ansibash pscpu
userrc :
	ansibash 'git clone https://github.com/sempernow/userrc 2>/dev/null || echo ok'
	ansibash 'pushd userrc && git pull && make sync-user && make user'
reboot : 
	ansibash sudo reboot

