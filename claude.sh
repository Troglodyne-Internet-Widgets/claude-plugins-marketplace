#!/usr/bin/env bash
#
# claude.sh - wrapper that makes `claude` print usage on an unrecognized
# subcommand instead of silently treating it as a prompt and dropping you into
# an interactive session.
#
# The command list is scraped from `claude --help` at runtime (cached), so this
# stays correct as the CLI gains and loses subcommands.
#
# Install:
#   cp claude.sh ~/.local/bin/claude.sh
#   alias claude='~/.local/bin/claude.sh'      # or drop it in PATH as `claude`
#
# Environment:
#   CLAUDE_BIN        path to the real claude binary (default: first `claude`
#                     on PATH that is not this script)
#   CLAUDE_SH_NOCACHE set to 1 to bypass the parsed-help cache
#
# Pass-through escape hatches (never validated, for when your prompt happens to
# look like a subcommand):
#   claude -- marketplace add foo     # everything after -- is a prompt
#   claude -p marketplace             # --print implies you meant a prompt
#   claude "marketplace add foo"      # a quoted multi-word prompt

set -uo pipefail

if [[ -z ${BASH_VERSINFO:-} || ${BASH_VERSINFO[0]} -lt 4 ]]; then
	echo "claude.sh: requires bash 4 or newer" >&2
	exit 2
fi

self=$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")

die() {
	echo "claude.sh: $*" >&2
	exit 2
}

# Locate the real claude, skipping this script so an `alias claude=claude.sh`
# or a PATH-shadowing install cannot recurse into itself.
resolve_claude() {
	if [[ -n ${CLAUDE_BIN:-} ]]; then
		[[ -x $CLAUDE_BIN ]] || die "CLAUDE_BIN is not executable: $CLAUDE_BIN"
		printf '%s' "$CLAUDE_BIN"
		return 0
	fi
	local dir cand rp
	while IFS= read -r dir; do
		[[ -n $dir ]] || continue
		cand="$dir/claude"
		[[ -f $cand && -x $cand ]] || continue
		rp=$(realpath "$cand" 2>/dev/null || printf '%s' "$cand")
		[[ $rp == "$self" ]] && continue
		printf '%s' "$cand"
		return 0
	done < <(printf '%s' "${PATH:-}" | tr ':' '\n')
	return 1
}

claude_bin=$(resolve_claude) || die "could not find the real \`claude\` on PATH (set CLAUDE_BIN)"

# No arguments at all is a legitimate interactive session.
(($#)) || exec "$claude_bin"

# ---------------------------------------------------------------- help cache

# Key the cache on the binary's mtime+size so a `claude update` invalidates it
# without paying for a `claude --version` spawn.
cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/claude-sh"
bin_real=$(realpath "$claude_bin" 2>/dev/null || printf '%s' "$claude_bin")
stamp=$(stat -c '%Y-%s' "$bin_real" 2>/dev/null || stat -f '%m-%z' "$bin_real" 2>/dev/null || echo nostat)

cache_get() { # <key>
	[[ ${CLAUDE_SH_NOCACHE:-0} == 1 ]] && return 1
	local f="$cache_dir/$stamp.$1"
	[[ -s $f ]] && cat "$f"
}

cache_put() { # <key> <<< content
	[[ ${CLAUDE_SH_NOCACHE:-0} == 1 ]] && { cat; return; }
	mkdir -p "$cache_dir" 2>/dev/null || { cat; return; }
	local f="$cache_dir/$stamp.$1"
	tee "$f.$$" >/dev/null && mv -f "$f.$$" "$f" 2>/dev/null
	cat "$f" 2>/dev/null
}

help_text=$("$claude_bin" --help 2>&1) || help_text=""

# ------------------------------------------------------------- help parsing

# Top-level command names, aliases expanded ("plugin|plugins" -> both).
# Description continuation lines are indented deeper than 2, so requiring a
# non-space in column 3 keeps them out.
parse_commands() {
	awk '
		/^Commands:/ { inblock = 1; next }
		inblock && /^[^ ]/ { inblock = 0 }
		inblock && /^  [^ ]/ {
			line = $0; sub(/^  /, "", line)
			split(line, f, /[ \t]/)
			tok = f[1]
			if (tok ~ /^-/) next
			n = split(tok, aliases, "|")
			for (i = 1; i <= n; i++) if (aliases[i] != "") print aliases[i]
		}
	'
}

# Emit "<flag>\t<none|value|variadic>" for every option, so we can tell
# `--model opus plugin list` (opus is a value) from `--verbose plugin list`.
parse_options() {
	awk '
		/^Options:/ { inblock = 1; next }
		/^Commands:/ { inblock = 0 }
		inblock && /^  -/ {
			line = $0; sub(/^  /, "", line)
			spec = line
			if (match(spec, /  +/)) spec = substr(spec, 1, RSTART - 1)

			kind = "none"
			if (spec ~ /[<[]/) kind = (spec ~ /\.\.\./) ? "variadic" : "value"

			names = spec
			if (match(names, /[<[]/)) names = substr(names, 1, RSTART - 1)
			gsub(/,/, " ", names)
			n = split(names, parts, /[ \t]+/)
			for (i = 1; i <= n; i++)
				if (parts[i] ~ /^-/) printf "%s\t%s\n", parts[i], kind
		}
	'
}

commands_list=$(cache_get commands) || true
if [[ -z $commands_list ]]; then
	commands_list=$(printf '%s\n' "$help_text" | parse_commands | cache_put commands)
fi

options_list=$(cache_get options) || true
if [[ -z $options_list ]]; then
	options_list=$(printf '%s\n' "$help_text" | parse_options | cache_put options)
fi

# Fail open: if the help format ever changes out from under us, get out of the
# way rather than blocking a valid command.
[[ -n $commands_list ]] || exec "$claude_bin" "$@"

declare -A is_command=()
while IFS= read -r c; do [[ -n $c ]] && is_command[$c]=1; done <<<"$commands_list"

declare -A opt_kind=()
while IFS=$'\t' read -r flag kind; do [[ -n $flag ]] && opt_kind[$flag]=$kind; done <<<"$options_list"

# ------------------------------------------------------- find the operand

# Walk the option soup the way commander does and stop at the first operand.
first_operand=""
saw_double_dash=0
saw_print=0
i=1
while ((i <= $#)); do
	arg=${!i}

	if [[ $arg == "--" ]]; then
		saw_double_dash=1
		break
	fi

	if [[ $arg == -* && $arg != "-" ]]; then
		[[ $arg == -p || $arg == --print ]] && saw_print=1
		# --opt=value carries its own argument
		if [[ $arg == --*=* ]]; then
			((i++))
			continue
		fi
		case ${opt_kind[$arg]:-none} in
		value)
			((i += 2))
			;;
		variadic)
			# Commander's variadic options swallow operands until the next flag.
			((i++))
			while ((i <= $#)); do
				next=${!i}
				[[ $next == -* && $next != "-" ]] && break
				((i++))
			done
			;;
		*)
			((i++))
			;;
		esac
		continue
	fi

	first_operand=$arg
	break
done

# Nothing to validate: pure options, or an explicit prompt escape hatch.
if [[ -z $first_operand || $saw_double_dash == 1 || $saw_print == 1 ]]; then
	exec "$claude_bin" "$@"
fi

# A known command, or something with whitespace in it (a quoted prompt like
# `claude "fix the build"`), passes through untouched.
if [[ -n ${is_command[$first_operand]:-} || $first_operand == *[[:space:]]* ]]; then
	exec "$claude_bin" "$@"
fi

# --------------------------------------------------------- unknown command

# Only on the error path: scan each command's own --help for a nested
# subcommand by this name, so `claude marketplace` can point at
# `claude plugin marketplace`. Spawned in parallel, then cached.
suggest_nested() {
	local scan c
	scan=$(cache_get subcommands) || true
	if [[ -z $scan ]]; then
		local tmp
		tmp=$(mktemp -d) || return 0
		for c in "${!is_command[@]}"; do
			{
				"$claude_bin" "$c" --help 2>/dev/null | parse_commands |
					while IFS= read -r sub; do [[ -n $sub ]] && printf '%s\t%s\n' "$sub" "$c"; done
			} >"$tmp/$c" &
		done
		wait
		scan=$(cat "$tmp"/* 2>/dev/null | sort -u | cache_put subcommands)
		rm -rf "$tmp"
	fi
	printf '%s\n' "$scan" | awk -F'\t' -v want="$1" '$1 == want { print $2 }' | head -1
}

{
	echo "claude.sh: unknown command '$first_operand'"

	parent=$(suggest_nested "$first_operand")
	if [[ -n $parent ]]; then
		echo
		echo "Did you mean:  claude $parent $first_operand ..."
	fi

	echo
	echo "If you meant to pass a prompt, quote it or use one of:"
	echo "  claude \"$first_operand ...\""
	echo "  claude -p $first_operand ..."
	echo "  claude -- $first_operand ..."
	echo
	printf '%s\n' "$help_text"
} >&2

exit 2
