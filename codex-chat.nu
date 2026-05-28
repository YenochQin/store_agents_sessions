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

def run-remap [codex_home: string, mapping_file: string, dry_run: bool] {
    let mappings = (load-path-mappings $mapping_file)

    let invalid = ($mappings | where { |m| ($m.to | str starts-with "FILL_IN") })
    if ($invalid | length) > 0 {
        print "The following mappings have placeholder 'to' values that must be filled in:"
        for m in $invalid {
            print $"  ($m.from) -> ($m.to)"
        }
        error make { msg: "Edit path-mapping.jsonl and replace FILL_IN_WINDOWS_PATH entries before running." }
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

    if ($files | length) == 0 {
        return
    }

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

def load-path-mappings [mapping_file: string] {
    assert-path $mapping_file "path mapping file"

    let lines = (read-jsonl-lines $mapping_file)
    let mappings = ($lines | each { |line| $line | from json })

    for mapping in $mappings {
        if not ("from" in $mapping) or not ("to" in $mapping) {
            error make { msg: $"Invalid mapping entry (missing 'from' or 'to'): ($mapping)" }
        }
    }

    $mappings | sort-by { |m| -($m.from | str length) }
}

def remap-cwd-in-file [file_path: string, mappings: list<any>, dry_run: bool] {
    let raw = (open --raw $file_path)
    let all_lines = ($raw | lines)

    if ($all_lines | length) == 0 {
        return "skip"
    }

    let first_line = ($all_lines | get 0)

    let cwd_match = ($first_line | parse --regex '"cwd":"(?P<cwd>[^"]*)"')
    if ($cwd_match | length) == 0 {
        return "skip"
    }

    let old_cwd = ($cwd_match | get 0 | get cwd)

    mut new_cwd = $old_cwd
    for mapping in $mappings {
        if ($old_cwd | str starts-with $mapping.from) {
            let suffix = ($old_cwd | str substring ($mapping.from | str length)..)
            let joined = $"($mapping.to)($suffix)"
            $new_cwd = (if $nu.os-info.name == "windows" {
                $joined | str replace --all "/" "\\"
            } else {
                $joined
            })
            break
        }
    }

    if $new_cwd == $old_cwd {
        return "unchanged"
    }

    if $dry_run {
        print $"  ($file_path | path basename): ($old_cwd) -> ($new_cwd)"
        return "would_remap"
    }

    let new_first_line = ($first_line | str replace $"\"cwd\":\"($old_cwd)\"" $"\"cwd\":\"($new_cwd)\"")
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

def main [] {
    print "Codex chat sync helper"
    print ""
    print "Commands:"
    print "  nu codex-chat.nu backup"
    print "  nu codex-chat.nu restore --backup-path ./codex-chat-sync/20260528-103000 --merge-folders"
    print "  nu codex-chat.nu restore --backup-path ./codex-chat-sync/20260528-103000 --replace-folders"
    print "  nu codex-chat.nu restore --backup-path ./codex-chat-sync/20260528-103000.zip --replace-folders"
    print "  nu codex-chat.nu merge-index --source-index ./codex-chat-sync/20260528-103000/session_index.jsonl"
    print "  nu codex-chat.nu remap-paths [--mapping-file path-mapping.jsonl] [--dry-run]"
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
        print $"Restore completed into: ($codex_home)"

        let mapping_file = (join-path [(script-dir) "path-mapping.jsonl"])
        if ($mapping_file | path exists) {
            print ""
            print "Running path remap..."
            try {
                run-remap $codex_home $mapping_file false
            } catch { |err|
                print $"Path remap skipped: ($err.msg)"
                print "Run 'nu codex-chat.nu remap-paths' manually after fixing path-mapping.jsonl."
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
        join-path [(script-dir) "path-mapping.jsonl"]
    } else {
        $mapping_file
    } | path expand)

    run-remap $codex_home $mf $dry_run
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
