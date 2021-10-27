#!/bin/bash
# requires: curl
set -e
set -o pipefail

function remove_broken() {
	interval=$1
	interval_file="${TUNASYNC_WORKING_DIR}/.tunasync_hackage_lastcheck"
	now=`date +%s`

	if [[ -f ${interval_file} ]]; then
		lastcheck=`cat ${interval_file}`
		((between = now - lastcheck))
		if ((between < interval)); then
			echo "skip checking"
			return 0
		fi
	fi
	echo "start checking"

	mkdir -p "${TUNASYNC_WORKING_DIR}/package"
	cd "${TUNASYNC_WORKING_DIR}/package"
	
	for line in *; do
		tar -tzf $line &>/dev/null || (printf 'FAIL %s\n' "$line"; rm $line) # && echo "OK"
	done
	
	echo `date +%s` > $interval_file
}

function must_download() {
	src=$1
	dst=$2
	while true; do
		echo "downloading: $dst"
		curl -s -S --fail -L "$src" -o "$dst"
		tar -tzf "$dst" >/dev/null || rm "$dst" && break 
	done
	return 0
}

function hackage_mirror() {
	local_pklist="/tmp/hackage_local_pklist_$$.list"
	remote_pklist="/tmp/hackage_remote_pklist_$$.list"
	base_url="https://hackage.haskell.org"
	
	cd ${TUNASYNC_WORKING_DIR}
	mkdir -p package

	echo "Downloading index..."
	rm index.tar.gz || true
	curl -s -S --fail -L "${base_url}/01-index.tar.gz" -o index.tar.gz 
	rm index-legacy.tar.gz || true
	curl -s -S --fail -L "${base_url}/00-index.tar.gz" -o index-legacy.tar.gz

	# https://hackage.haskell.org/api#security
	echo "Dowloading security features..."
	jsons=("timestamp.json" "snapshot.json" "root.json" "mirrors.json")
	for name in "${jsons[@]}"
	do
    		curl -s -S --fail -L "${base_url}/${name}" -o "${name}"
	done
	
	echo "building local package list"
	local tmp
	tmp=(package/*)
	tmp=(${tmp[@]#package/})
	printf '%s\n' "${tmp[@]%.tar.gz}" | sort | uniq > "${local_pklist}"
	
	echo "building remote package list"
	tar -ztf index.tar.gz | (cut -d/ -f 1,2 2>/dev/null) | sed 's|/|-|' | sort | uniq > "${remote_pklist}"
	
	echo "building download list"
	# subtract local list from remote list
	# this cannot use pipe, or the `wait` afterwards cannot wait
	# because pipe spawns a subshell
	while read pk; do
		# ignore package suffix "preferred-versions"
		# echo $pk
		if [[ $pk = *-preferred-versions ]]; then
			continue
		fi
		# limit concurrent level
		bgcount=`jobs | wc -l`
		while [[ $bgcount -ge 5 ]]; do
			sleep 0.5
			bgcount=`jobs | wc -l`
		done
		
		name="$pk.tar.gz"
		if [ ! -e package/$name ]; then
			must_download "${base_url}/package/$pk/$name" "package/$name" &
		else
			echo "skip existed: $name"
		fi
	done < <(comm "${remote_pklist}" "${local_pklist}" -23)
	
	wait
	
	# delete redundanty files
	comm "$remote_pklist" "$local_pklist" -13 | while read pk; do
		if [[ $pk == "preferred-versions" ]]; then
			continue
		fi
		name="${pk}.tar.gz"
		echo "deleting ${name}"
		rm "package/$name"
	done

	cp index.tar.gz 01-index.tar.gz
	cp index-legacy.tar.gz 00-index.tar.gz
}

function cleanup () {
	echo "cleaning up"
	[[ ! -z $local_pklist ]] && (rm $local_pklist $remote_pklist ; true)
}

trap cleanup EXIT
remove_broken 86400
hackage_mirror 

# vim: ts=4 sts=4 sw=4
