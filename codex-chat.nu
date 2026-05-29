#!/usr/bin/env nu

const SYNC_DIR_NAME = "codex-chat-sync"

def script-dir [] {
    let file_pwd = ($env.FILE_PWD? | default null)

    if $file_pwd == null {
        pwd
    } else {
        $file_pwd
    }
}

def join-path [parts: list<any>] {
    $parts | each { |part| $part | into string } | path join
}

def default-codex-home [] {
    join-path [$nu.home-dir ".codex"]
}

def default-sync-root [] {
    join-path [(script-dir) $SYNC_DIR_NAME]
}

def default-path-mapping-file [] {
    let toml = (join-path [(script-dir) "path-mapping.toml"])
    let jsonl = (join-path [(script-dir) "path-mapping.jsonl"])

    if ($toml | path exists) {
        $toml
    } else {
        $jsonl
    }
}

def codex-running [] {
    (ps | where { |process| ($process.name | str downcase) =~ "codex" } | length) > 0
}

def assert-path [path: string, description: string] {
    if not ($path | path exists) {
        error make { msg: $"Missing ($description): ($path)" }
    }
}

def unique-backup-path [root: string, prefix?: string] {
    let timestamp = (date now | format date "%Y%m%d-%H%M%S")
    let name = if ($prefix | default "" | is-empty) {
        $timestamp
    } else {
        $"($prefix)-($timestamp)"
    }

    mut candidate = (join-path [$root $name])
    mut counter = 1

    while ($candidate | path exists) {
        let suffix = if $counter < 10 { $"0($counter)" } else { $counter | into string }
        $candidate = (join-path [$root $"($name)-($suffix)"])
        $counter = $counter + 1
    }

    $candidate
}

def read-jsonl-lines [path: string] {
    if not ($path | path exists) {
        []
    } else {
        open --raw $path | lines | where { |line| ($line | str trim | str length) > 0 }
    }
}

def merge-index-lines [source: string, destination: string, create_destination: bool] {
    assert-path $source "source session_index.jsonl"

    let destination_dir = ($destination | path dirname)
    assert-path $destination_dir "destination directory"

    if not ($destination | path exists) {
        if not $create_destination {
            error make { msg: $"Destination index does not exist: ($destination). Use --create-destination to create it." }
        }

        "" | save --force $destination
    }

    let existing_lines = (read-jsonl-lines $destination)
    let source_lines = (read-jsonl-lines $source)

    let to_append = ($source_lines
        | where { |line| $line not-in $existing_lines }
        | reduce -f [] { |line, acc| if $line not-in $acc { $acc | append $line } else { $acc } })

    if ($to_append | length) == 0 {
        print "No new index lines to merge."
        return
    }

    let destination_raw = (open --raw $destination)
    let needs_leading_newline = (($destination_raw | str length) > 0) and (not ($destination_raw | str ends-with (char nl)))
    let prefix = if $needs_leading_newline { char nl } else { "" }
    let text = ($prefix + ($to_append | str join (char nl)) + (char nl))

    $text | save --append $destination
    print $"Merged (($to_append | length)) new index lines into: ($destination)"
}

def copy-if-exists [source: string, destination: string] {
    if ($source | path exists) {
        cp -r $source $destination
    }
}

# Codex App stores its thread index in a versioned sqlite file (state_<n>.sqlite).
# The CLI uses session_index.jsonl instead; this file may be absent on CLI-only setups.
def find-app-db-files [codex_home: string] {
    if not ($codex_home | path exists) {
        []
    } else {
        ls $codex_home
        | where { |entry| (($entry.name | path basename) =~ '^state_\d+\.sqlite$') }
        | get name
        | each { |name| $name | into string }
    }
}

# Checkpoint the WAL into the main file, then copy only the main .sqlite. If the
# checkpoint fails (e.g. a writer holds the lock), fall back to copying -wal/-shm so
# the copied set stays self-consistent.
def backup-app-db [codex_home: string, destination: string] {
    for db in (find-app-db-files $codex_home) {
        let base = ($db | path basename)
        let checkpointed = (try {
            open $db | query db "PRAGMA wal_checkpoint(TRUNCATE)" | ignore
            true
        } catch { false })

        cp $db (join-path [$destination $base])

        if not $checkpointed {
            for suffix in ["-wal" "-shm"] {
                let extra = $"($db)($suffix)"
                if ($extra | path exists) {
                    cp $extra (join-path [$destination $"($base)($suffix)"])
                }
            }
        }
    }
}

# Tables in the App db that are keyed per thread and worth carrying across a restore.
# Listed parent-first so child rows always find their thread on INSERT OR IGNORE.
def app-db-tables [] {
    ["threads" "thread_dynamic_tools" "stage1_outputs" "thread_spawn_edges"]
}

# Copy rows that don't already exist (by primary key) from one App db into another.
# Only columns present in BOTH databases are used, so the merge survives schema drift
# between Codex builds. NULL cells are omitted per row (query db -p drops nulls).
def merge-app-db-table [local_db: string, backup_db: string, table: string] {
    let backup_cols = (open $backup_db | query db $"PRAGMA table_info\(($table)\)" | get name)
    let local_cols = (open $local_db | query db $"PRAGMA table_info\(($table)\)" | get name)
    let cols = ($backup_cols | where { |c| $c in $local_cols })
    if ($cols | is-empty) {
        return
    }

    for row in (open $backup_db | query db $"SELECT * FROM ($table)") {
        let present = ($cols | where { |c| ($row | get $c) != null })
        if ($present | is-empty) {
            continue
        }
        let collist = ($present | str join ", ")
        let placeholders = ($present | each { |_| "?" } | str join ", ")
        let params = ($present | each { |c| $row | get $c })
        open $local_db | query db $"INSERT OR IGNORE INTO ($table) \(($collist)\) VALUES \(($placeholders)\)" -p $params
    }
}

# Bring the backup's App threads into the local codex home. The App db is NEVER copied
# wholesale across machines: its _sqlx_migrations checksums are build-specific, so a
# foreign file makes Codex refuse to launch ("migration N ... has been modified"). When
# a local db exists we merge thread rows into it (preserving the local schema and
# migrations). When it does not, we skip and tell the user to let Codex create it first.
# Path remapping happens afterwards via run-remap.
def restore-app-db [backup: string, codex_home: string] {
    for backup_db in (find-app-db-files $backup) {
        let base = ($backup_db | path basename)
        let local_db = (join-path [$codex_home $base])

        if ($local_db | path exists) {
            for table in (app-db-tables) {
                merge-app-db-table $local_db $backup_db $table
            }
        } else {
            print $"No local ($base) found; skipping App db restore. Launch Codex once to create it, then re-run restore to merge threads. \(Copying the backup db would break Codex's migration check.\)"
        }
    }
}

def copy-missing-tree-items [source_root: string, destination_root: string] {
    mkdir $destination_root

    for entry in (ls -a $source_root) {
        let target = (join-path [$destination_root ($entry.name | path basename)])

        if (($entry.type | into string) == "dir") {
            copy-missing-tree-items $entry.name $target
        } else if not ($target | path exists) {
            mkdir ($target | path dirname)
            cp $entry.name $target
        }
    }
}

def create-zip [source_dir: string, zip_path: string] {
    let parent = ($source_dir | path dirname)
    let leaf = ($source_dir | path basename)
    let zip_abs = ($zip_path | path expand)

    if $nu.os-info.name == "windows" {
        ^tar -a -cf $zip_abs -C $parent $leaf
    } else {
        do { cd $parent; ^zip -rq $zip_abs $leaf }
    }
}

def temp-root [] {
    if $nu.os-info.name == "windows" {
        $env.TEMP? | default ($env.TMP? | default "C:\\Windows\\Temp")
    } else {
        $env.TMPDIR? | default "/tmp"
    }
}

def extract-zip [zip_path: string, target_dir: string] {
    mkdir $target_dir
    let zip_abs = ($zip_path | path expand)

    try {
        if $nu.os-info.name == "windows" {
            let system_tar = "C:\\Windows\\System32\\tar.exe"
            if ($system_tar | path exists) {
                ^$system_tar -xf $zip_abs -C $target_dir
            } else {
                ^tar -xf $zip_abs -C $target_dir
            }
        } else {
            ^unzip -q $zip_abs -d $target_dir
        }
    } catch { |err|
        if ($target_dir | path exists) {
            rm -r -f $target_dir
        }
        error make { msg: $"Failed to extract zip ($zip_abs): ($err.msg)" }
    }
}

def resolve-backup-source [backup_path: string] {
    let is_zip_file = (
        (($backup_path | path type) == "file")
        and (($backup_path | str downcase | str ends-with ".zip"))
    )

    if not $is_zip_file {
        return { root: $backup_path, temp: "" }
    }

    let timestamp = (date now | format date "%Y%m%d-%H%M%S-%f")
    let temp_dir = (join-path [(temp-root) $"codex-chat-restore-($timestamp)"])
    extract-zip $backup_path $temp_dir

    let subdirs = (
        ls -a $temp_dir
        | where { |entry| ($entry.type | into string) == "dir" }
    )

    let root = if ($subdirs | length) == 1 {
        ($subdirs | get 0 | get name)
    } else {
        $temp_dir
    }

    { root: $root, temp: $temp_dir }
}

def find-jsonl-files [dir: string] {
    ls -a $dir | reduce -f [] { |entry, acc|
        if (($entry.type | into string) == "dir") {
            $acc | append (find-jsonl-files $entry.name)
        } else if ($entry.name | str ends-with ".jsonl") {
            $acc | append $entry.name
        } else {
            $acc
        }
    }
}

# Gather every distinct project cwd that actually appears in local Codex records.
# Sources: the first line (payload.cwd) of each rollout JSONL under sessions/ and
# archived_sessions/, plus threads.cwd in each state_*.sqlite. Extended-length \\?\
# prefixes are stripped so the values compare cleanly against mapping-file entries.
def collect-known-cwds [codex_home: string] {
    let sessions_dir = (join-path [$codex_home "sessions"])
    let archived_dir = (join-path [$codex_home "archived_sessions"])

    mut files = []
    if ($sessions_dir | path exists) {
        $files = ($files | append (find-jsonl-files $sessions_dir))
    }
    if ($archived_dir | path exists) {
        $files = ($files | append (find-jsonl-files $archived_dir))
    }

    mut cwds = []

    for file in $files {
        let cwd = (try {
            open --raw ($file | into string) | lines | get 0 | from json | get payload.cwd?
        } catch {
            null
        })
        if ($cwd != null) and (not ($cwd | into string | is-empty)) {
            $cwds = ($cwds | append ($cwd | into string))
        }
    }

    for db in (find-app-db-files $codex_home) {
        let rows = (try {
            open $db | query db "SELECT DISTINCT cwd FROM threads" | get cwd
        } catch {
            []
        })
        for cwd in $rows {
            if ($cwd != null) and (not ($cwd | into string | is-empty)) {
                $cwds = ($cwds | append ($cwd | into string))
            }
        }
    }

    $cwds | each { |c| strip-extended-prefix $c } | uniq | sort
}

# Return the subset of cwds not covered by any registered project path. A cwd is
# "covered" when it starts with a registered absolute path on ANY platform (a backup
# may have been written on either machine), so the covered-prefix set is built from
# every non-empty windows/macos/linux value in the mapping file.
def uncovered-cwds [cwds: list<string>, mapping_file: string] {
    let records = (read-path-mapping-records $mapping_file)
    let platform_keys = ["macos" "windows" "linux"]

    mut prefixes = []
    for record in $records {
        for key in $platform_keys {
            let value = (get-record-value $record $key)
            if ($value != null) and (not ($value | into string | is-empty)) {
                $prefixes = ($prefixes | append ($value | into string))
            }
        }
    }

    $cwds | where { |cwd|
        ($prefixes | where { |p| $cwd | str starts-with $p } | is-empty)
    }
}

# Infer which platform a stored cwd was written on, from its shape: a drive-letter
# (C:\, D:\) or UNC/backslash path is Windows; a leading "/" is macOS/Linux (POSIX).
# A discovered cwd belongs to whatever machine wrote it, not necessarily this one,
# so the emitted block keys the real path under the inferred platform.
def infer-path-platform [path: string] {
    if ($path =~ '^[A-Za-z]:[\\/]') or ($path | str starts-with '\\') {
        "windows"
    } else if ($path | str starts-with "/") {
        "macos"
    } else {
        current-path-platform
    }
}

# Suggest a [paths.<name>] slug from a cwd: lowercase the last path segment and
# collapse non-alphanumeric runs to single dashes. Purely a convenience for the
# emitted block; the user resolves any collisions when editing the file.
def suggest-paths-name [cwd: string] {
    let leaf = ($cwd | str replace --all "\\" "/" | path basename)
    let slug = ($leaf | str downcase | str replace --all --regex '[^a-z0-9]+' '-' | str trim --char '-')
    if ($slug | is-empty) { "project" } else { $slug }
}

def run-remap [codex_home: string, mapping_file: string, dry_run: bool] {
    let mappings = (load-path-mappings $mapping_file)

    let invalid = ($mappings | where { |m| ($m.to | str starts-with "FILL_IN") or ($m.from | str starts-with "FILL_IN") })
    if ($invalid | length) > 0 {
        print "The following mappings have placeholder values that must be filled in:"
        for m in $invalid {
            print $"  ($m.from) -> ($m.to)"
        }
        error make { msg: "Edit the path mapping file and replace FILL_IN placeholder entries before running." }
    }

    let sessions_dir = (join-path [$codex_home "sessions"])
    let archived_dir = (join-path [$codex_home "archived_sessions"])

    mut files = []
    if ($sessions_dir | path exists) {
        $files = ($files | append (find-jsonl-files $sessions_dir))
    }
    if ($archived_dir | path exists) {
        $files = ($files | append (find-jsonl-files $archived_dir))
    }

    if ($files | length) > 0 {
        if $dry_run {
            print "Dry run - no files will be modified:"
        }

        mut remapped = 0
        mut unchanged = 0
        mut skipped = 0

        for file in $files {
            let result = (remap-cwd-in-file ($file | into string) $mappings $dry_run)
            if $result == "remapped" or $result == "would_remap" {
                $remapped = $remapped + 1
            } else if $result == "unchanged" {
                $unchanged = $unchanged + 1
            } else {
                $skipped = $skipped + 1
            }
        }

        print $"Remapped: ($remapped), Unchanged: ($unchanged), Skipped: ($skipped)"
    }

    for db in (find-app-db-files $codex_home) {
        remap-sqlite $db $codex_home $mappings $dry_run
    }
}

def load-path-mappings [mapping_file: string] {
    assert-path $mapping_file "path mapping file"

    let mappings = (read-path-mapping-records $mapping_file)
    let target_platform = (current-path-platform)
    let platform_keys = ["macos" "windows" "linux"]
    mut normalized = []

    for mapping in $mappings {
        if ("from" in $mapping) and ("to" in $mapping) {
            $normalized = ($normalized | append { from: $mapping.from, to: $mapping.to, target_platform: $target_platform })
            continue
        }

        let target = (get-record-value $mapping $target_platform)
        if ($target == null) or (($target | into string | is-empty)) {
            continue
        }

        for source_platform in $platform_keys {
            if $source_platform == $target_platform {
                continue
            }

            let source = (get-record-value $mapping $source_platform)
            if ($source == null) or (($source | into string | is-empty)) {
                continue
            }

            $normalized = ($normalized | append {
                from: ($source | into string)
                to: ($target | into string)
                target_platform: $target_platform
            })
        }
    }

    if ($normalized | length) == 0 {
        error make { msg: $"No usable mappings for current platform: ($target_platform)" }
    }

    $normalized | sort-by { |m| -($m.from | str length) }
}

def read-path-mapping-records [mapping_file: string] {
    let extension = ($mapping_file | path parse | get extension | str downcase)

    if $extension == "toml" {
        let data = (open $mapping_file)
        let paths = (get-record-value $data "paths")

        if $paths == null {
            error make { msg: $"TOML mapping file must contain a [paths.*] table: ($mapping_file)" }
        }

        $paths | transpose name mapping | each { |entry| $entry.mapping }
    } else {
        let lines = (read-jsonl-lines $mapping_file)
        $lines | each { |line| $line | from json }
    }
}

def current-path-platform [] {
    if $nu.os-info.name == "macos" {
        "macos"
    } else if $nu.os-info.name == "windows" {
        "windows"
    } else if $nu.os-info.name == "linux" {
        "linux"
    } else {
        $nu.os-info.name
    }
}

def get-record-value [record: record, key: string] {
    try {
        $record | get $key
    } catch {
        null
    }
}

def normalize-path-for-platform [path: string, platform: string] {
    if $platform == "windows" {
        $path | str replace --all "/" "\\"
    } else {
        $path | str replace --all "\\" "/"
    }
}

# Codex stores some Windows paths with the extended-length prefix (\\?\ or \\?\UNC\).
# Strip it so prefix matching against clean mapping keys works.
def strip-extended-prefix [path: string] {
    if ($path | str starts-with '\\?\UNC\') {
        '\\' + ($path | str substring 8..)
    } else if ($path | str starts-with '\\?\') {
        $path | str substring 4..
    } else {
        $path
    }
}

# Apply the first matching mapping (mappings are pre-sorted longest-first) to a path
# string. Returns the remapped path, or the original unchanged if nothing matches.
def remap-path-string [path: string, mappings: list<any>] {
    let stripped = (strip-extended-prefix $path)
    mut result = $path
    for mapping in $mappings {
        if ($stripped | str starts-with $mapping.from) {
            let suffix = ($stripped | str substring ($mapping.from | str length)..)
            let joined = $"($mapping.to)($suffix)"
            $result = (normalize-path-for-platform $joined $mapping.target_platform)
            break
        }
    }
    $result
}

def remap-cwd-in-file [file_path: string, mappings: list<any>, dry_run: bool] {
    let raw = (open --raw $file_path)
    let all_lines = ($raw | lines)

    if ($all_lines | length) == 0 {
        return "skip"
    }

    let first_record = try {
        $all_lines | get 0 | from json
    } catch {
        return "skip"
    }

    let old_cwd = try {
        $first_record.payload.cwd
    } catch {
        return "skip"
    }

    let new_cwd = (remap-path-string $old_cwd $mappings)

    if $new_cwd == $old_cwd {
        return "unchanged"
    }

    if $dry_run {
        print $"  ($file_path | path basename): ($old_cwd) -> ($new_cwd)"
        return "would_remap"
    }

    let new_first_line = ($first_record | upsert payload.cwd $new_cwd | to json --raw)
    let rest = ($all_lines | skip 1)
    let new_content = ([$new_first_line] | append $rest | str join (char nl))

    let final_content = if ($raw | str ends-with (char nl)) {
        $new_content + (char nl)
    } else {
        $new_content
    }

    $final_content | save --force $file_path
    "remapped"
}

# Re-root an absolute Codex path (e.g. a stored rollout_path) onto the local codex
# home, regardless of which machine wrote it. Splits on the ".codex" segment and
# rejoins the suffix onto $codex_home, normalizing separators for this platform.
def reroot-codex-path [stored: string, codex_home: string] {
    let normalized = ($stored | str replace --all "\\" "/")
    let parts = ($normalized | split row "/.codex/")

    if ($parts | length) < 2 {
        $stored
    } else {
        let suffix = ($parts | skip 1 | str join "/.codex/")
        normalize-path-for-platform $"($codex_home)/($suffix)" (current-path-platform)
    }
}

# Remap the Codex App's thread index. For every row in `threads`:
#   cwd          -> remapped via path mappings (handles \\?\ prefixes)
#   rollout_path -> re-rooted onto the local codex_home
#   agent_path   -> remapped via path mappings when present
def remap-sqlite [db_path: string, codex_home: string, mappings: list<any>, dry_run: bool] {
    if not ($db_path | path exists) {
        return
    }

    let rows = (open $db_path | query db "SELECT id, cwd, rollout_path, agent_path FROM threads")

    if $dry_run {
        print "Dry run - sqlite threads will not be modified:"
    }

    mut remapped = 0
    mut unchanged = 0

    for row in $rows {
        let new_cwd = (remap-path-string $row.cwd $mappings)
        let new_rollout = (reroot-codex-path $row.rollout_path $codex_home)
        let new_agent = if ($row.agent_path | is-empty) {
            $row.agent_path
        } else {
            remap-path-string $row.agent_path $mappings
        }

        let changed = ($new_cwd != $row.cwd) or ($new_rollout != $row.rollout_path) or ($new_agent != $row.agent_path)

        if not $changed {
            $unchanged = $unchanged + 1
            continue
        }

        if $dry_run {
            print $"  thread ($row.id): cwd ($row.cwd) -> ($new_cwd)"
            $remapped = $remapped + 1
            continue
        }

        open $db_path | query db "UPDATE threads SET cwd = ?, rollout_path = ?, agent_path = ? WHERE id = ?" -p [$new_cwd $new_rollout $new_agent $row.id]
        $remapped = $remapped + 1
    }

    print $"sqlite threads remapped: ($remapped), unchanged: ($unchanged)"
}

def main [] {
    print "Codex chat sync helper"
    print ""
    print "Backs up/restores sessions, archived_sessions, session_index.jsonl, and the"
    print "App thread index state_*.sqlite. Restore remaps project cwd (incl. \\\\?\\ paths)"
    print "via path-mapping.toml and re-roots rollout_path onto the local codex home."
    print ""
    print "Commands:"
    print "  nu codex-chat.nu backup"
    print "  nu codex-chat.nu restore --backup-path ./codex-chat-sync/20260528-103000 --merge-folders"
    print "  nu codex-chat.nu restore --backup-path ./codex-chat-sync/20260528-103000 --replace-folders"
    print "  nu codex-chat.nu restore --backup-path ./codex-chat-sync/20260528-103000.zip --replace-folders"
    print "  nu codex-chat.nu merge-index --source-index ./codex-chat-sync/20260528-103000/session_index.jsonl"
    print "  nu codex-chat.nu remap-paths [--mapping-file path-mapping.toml] [--dry-run]"
    print "  nu codex-chat.nu discover-paths [--mapping-file path-mapping.toml] [--write]"
    print "  nu codex-chat.nu compress"
}

def "main backup" [
    --codex-home: string
    --backup-root: string
    --zip
    --ignore-running-codex
] {
    let codex_home = (if $codex_home == null { default-codex-home } else { $codex_home } | path expand)
    let backup_root = (if $backup_root == null { default-sync-root } else { $backup_root } | path expand)

    if (codex-running) and (not $ignore_running_codex) {
        error make { msg: "Codex appears to be running. Close Codex App before backup, or rerun with --ignore-running-codex if you accept the risk." }
    }

    let sessions = (join-path [$codex_home "sessions"])
    let archived_sessions = (join-path [$codex_home "archived_sessions"])
    let index = (join-path [$codex_home "session_index.jsonl"])

    assert-path $sessions "Codex sessions path"
    assert-path $archived_sessions "Codex archived_sessions path"
    assert-path $index "Codex session_index.jsonl"

    mkdir $backup_root
    let destination = (unique-backup-path $backup_root)

    mkdir $destination
    cp -r $sessions (join-path [$destination "sessions"])
    cp -r $archived_sessions (join-path [$destination "archived_sessions"])
    cp $index (join-path [$destination "session_index.jsonl"])
    backup-app-db $codex_home $destination

    if $zip {
        let zip_path = $"($destination).zip"
        create-zip $destination $zip_path
        rm -r -f $destination
        print $"Backup created: ($zip_path)"
    } else {
        print $"Backup created: ($destination)"
    }
}

def "main restore" [
    --backup-path: string
    --codex-home: string
    --safety-backup-root: string
    --merge-folders
    --replace-folders
    --ignore-running-codex
] {
    if $backup_path == null {
        error make { msg: "Missing required option: --backup-path" }
    }

    if $merge_folders and $replace_folders {
        error make { msg: "Use only one mode: --merge-folders or --replace-folders." }
    }

    let backup_expanded = ($backup_path | path expand)
    let codex_home = (if $codex_home == null { default-codex-home } else { $codex_home } | path expand)
    let safety_root = (if $safety_backup_root == null { default-sync-root } else { $safety_backup_root } | path expand)

    if (codex-running) and (not $ignore_running_codex) {
        error make { msg: "Codex appears to be running. Close Codex App before restore, or rerun with --ignore-running-codex if you accept the risk." }
    }

    let resolved = (resolve-backup-source $backup_expanded)
    let backup = $resolved.root
    let temp_extract = $resolved.temp

    try {
        let backup_sessions = (join-path [$backup "sessions"])
        let backup_archived_sessions = (join-path [$backup "archived_sessions"])
        let backup_index = (join-path [$backup "session_index.jsonl"])

        assert-path $backup_sessions "backup sessions"
        assert-path $backup_archived_sessions "backup archived_sessions"
        assert-path $backup_index "backup session_index.jsonl"

        mkdir $codex_home
        mkdir $safety_root

        let local_sessions = (join-path [$codex_home "sessions"])
        let local_archived_sessions = (join-path [$codex_home "archived_sessions"])
        let local_index = (join-path [$codex_home "session_index.jsonl"])

        if not $merge_folders {
            for target in [$local_sessions $local_archived_sessions] {
                if ($target | path exists) and (not $replace_folders) {
                    error make { msg: $"Destination folder already exists: ($target). Rerun with --merge-folders to add missing files or --replace-folders to replace Codex chat folders." }
                }
            }
        }

        let safety_backup = (unique-backup-path $safety_root "before-restore")
        mkdir $safety_backup
        copy-if-exists $local_sessions (join-path [$safety_backup "sessions"])
        copy-if-exists $local_archived_sessions (join-path [$safety_backup "archived_sessions"])
        copy-if-exists $local_index (join-path [$safety_backup "session_index.jsonl"])
        for db in (find-app-db-files $codex_home) {
            copy-if-exists $db (join-path [$safety_backup ($db | path basename)])
        }
        print $"Safety backup created: ($safety_backup)"

        if $merge_folders {
            copy-missing-tree-items $backup_sessions $local_sessions
            copy-missing-tree-items $backup_archived_sessions $local_archived_sessions
        } else if $replace_folders {
            for target in [$local_sessions $local_archived_sessions] {
                if ($target | path exists) {
                    rm -r -f $target
                }
            }

            cp -r $backup_sessions $local_sessions
            cp -r $backup_archived_sessions $local_archived_sessions
        } else {
            cp -r $backup_sessions $local_sessions
            cp -r $backup_archived_sessions $local_archived_sessions
        }

        if $replace_folders {
            cp $backup_index $local_index
            print $"Replaced session index: ($local_index)"
        } else {
            if not ($local_index | path exists) {
                "" | save --force $local_index
            }

            merge-index-lines $backup_index $local_index true
        }

        restore-app-db $backup $codex_home

        print $"Restore completed into: ($codex_home)"

        let mapping_file = (default-path-mapping-file)
        if ($mapping_file | path exists) {
            print ""
            print "Running path remap..."
            try {
                run-remap $codex_home $mapping_file false
            } catch { |err|
                print $"Path remap skipped: ($err.msg)"
                print "Run 'nu codex-chat.nu remap-paths' manually after fixing the path mapping file."
            }
        }
    } catch { |err|
        if (($temp_extract | str length) > 0) and ($temp_extract | path exists) {
            rm -r -f $temp_extract
        }
        error make { msg: $err.msg }
    }

    if (($temp_extract | str length) > 0) and ($temp_extract | path exists) {
        rm -r -f $temp_extract
    }
}

def "main merge-index" [
    --source-index: string
    --destination-index: string
    --create-destination
] {
    if $source_index == null {
        error make { msg: "Missing required option: --source-index" }
    }

    let source = ($source_index | path expand)
    let destination = (if $destination_index == null {
        join-path [(default-codex-home) "session_index.jsonl"]
    } else {
        $destination_index
    } | path expand)

    merge-index-lines $source $destination $create_destination
}

def "main remap-paths" [
    --codex-home: string
    --mapping-file: string
    --dry-run
] {
    let codex_home = (if $codex_home == null { default-codex-home } else { $codex_home } | path expand)
    let mf = (if $mapping_file == null {
        default-path-mapping-file
    } else {
        $mapping_file
    } | path expand)

    run-remap $codex_home $mf $dry_run
}

def "main discover-paths" [
    --codex-home: string
    --mapping-file: string
    --write
] {
    let codex_home = (if $codex_home == null { default-codex-home } else { $codex_home } | path expand)
    let mf = (if $mapping_file == null {
        default-path-mapping-file
    } else {
        $mapping_file
    } | path expand)

    assert-path $mf "path mapping file"

    let all_keys = ["macos" "windows" "linux"]

    let uncovered = (uncovered-cwds (collect-known-cwds $codex_home) $mf)

    if ($uncovered | is-empty) {
        print "All known cwd paths are covered by the mapping file."
        return
    }

    print $"Found (($uncovered | length)) project path\(s) not covered by ($mf):"
    print ""

    let blocks = ($uncovered | each { |cwd|
        let name = (suggest-paths-name $cwd)
        let owner = (infer-path-platform $cwd)
        let quote = if $owner == "windows" { "'" } else { '"' }
        mut lines = [$"[paths.($name)]" $"($owner) = ($quote)($cwd)($quote)"]
        for key in ($all_keys | where { |k| $k != $owner }) {
            $lines = ($lines | append $"($key) = \"FILL_IN\"")
        }
        $lines | str join (char nl)
    })

    print ($blocks | str join $"(char nl)(char nl)")
    print ""

    if not $write {
        print "Dry run. Re-run with --write to append these entries to the mapping file."
        return
    }

    let extension = ($mf | path parse | get extension | str downcase)
    if $extension != "toml" {
        error make { msg: $"--write only supports the TOML mapping file \(found .($extension)\): ($mf). The jsonl format has no [paths.*] table to append to." }
    }

    let existing_raw = (open --raw $mf)
    let needs_leading_newline = (($existing_raw | str length) > 0) and (not ($existing_raw | str ends-with (char nl)))
    let separator = if $needs_leading_newline { (char nl) + (char nl) } else { (char nl) }
    let text = $separator + ($blocks | str join $"(char nl)(char nl)") + (char nl)

    $text | save --append $mf
    print $"Appended (($uncovered | length)) entry\(ies\) to: ($mf)"
    print $"Edit it to fill in the FILL_IN value\(s\) for the other platform\(s\)."
}

def "main compress" [
    --backup-root: string
    --older-than-days: int = 30
    --remove-original
] {
    let backup_root = (if $backup_root == null { default-sync-root } else { $backup_root } | path expand)
    assert-path $backup_root "backup root"

    let cutoff = ((date now) - ($older_than_days * 1day))
    let folders = (
        ls $backup_root
        | where { |entry|
            (($entry.type | into string) == "dir")
            and (($entry.name | path basename) =~ '^\d{8}-\d{6}(-\d+)?$')
            and ($entry.modified < $cutoff)
        }
    )

    if ($folders | length) == 0 {
        print $"No backup folders older than ($older_than_days) days found."
        return
    }

    for folder in $folders {
        let zip_path = $"($folder.name).zip"
        create-zip $folder.name $zip_path
        print $"Zip created: ($zip_path)"

        if $remove_original {
            rm -r -f $folder.name
            print $"Removed original folder: ($folder.name)"
        }
    }
}
