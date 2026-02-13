#!/usr/bin/env bash
######################################
# Proxmox Virtual Environment (PVE)
######################################

creds(){
    type -t agede >/dev/null &&
        agede creds.proxmox.age
}
html(){
    type -t md2html.exe >/dev/null &&
        find . -type f -iname '*.md' -exec md2html.exe {} \;
    mode  
}
mode(){
    find . -type f ! -path '*/.git/*' -exec chmod 640 {} \+
}
commit(){
    html
    gc && git push && gl && gs ||
        echo "⚠️  This is NOT a Git repo"
}
pull(){
    scp -rp proxmox:logs pve/
    scp -rp proxmox:k0s-lab pve/
}
push(){
    scp -rp  pve/k0s-lab/ proxmox:.
}


[[ $1 ]] || { cat $BASH_SOURCE; exit 1; }

"$@" || echo "❌ ERR : $? at '${BASH_SOURCE##*/} $@'"
