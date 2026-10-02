# RC6A: run the commands of a file (one sh command per line), JOBS at a time,
# with the shell's own background jobs. No xargs: on 2026-10-01 a stray
# SIGTERM to xargs from another job on this machine killed the bench's pool
# mid-run, while the vvp runs it had started went on as orphans. Each job
# leaves a marker when its command returns; the pool throttles on the
# markers and ends with `wait`. Sourced by sim/run_rc6_r1.sh and
# sim/tb_rc6a_t9s.sh.
rc6a_pool() {   # command-file marker-dir
	_pd=$2
	rm -rf "$_pd"; mkdir -p "$_pd"
	_pi=0
	while IFS= read -r _pc; do
		[ -z "$_pc" ] && continue
		while [ $((_pi - $(ls "$_pd" | wc -l))) -ge "$JOBS" ]; do sleep 3; done
		_pi=$((_pi + 1))
		( sh -c "$_pc" < /dev/null || true; : > "$_pd/$_pi" ) &
	done < "$1"
	wait
	rm -rf "$_pd"
}
