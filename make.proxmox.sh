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
bundle(){
    git bundle create ../$(basename $(pwd)).bundle --all
}
pull(){
    #scp -rp pve:logs .
    #scp -rp pve:k0s-lab .
    rsync -atuvz --exclude='.git' root@pve:logs .
    rsync -atuvz --exclude='.git' root@pve:k0s-lab .
}
push(){
    #scp -rp  k0s-lab/ pve:.
    rsync -atuvz --exclude='.git' logs    root@pve:.   
    rsync -atuvz --exclude='.git' k0s-lab root@pve:.  
}


[[ $1 ]] || { cat $BASH_SOURCE; exit 1; }

"$@" || echo "❌ ERR : $? at '${BASH_SOURCE##*/} $@'"
