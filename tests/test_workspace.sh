#!/usr/bin/env bash
# shellcheck shell=bash
#
# Unit tests: the isolated workspace layout.

test_workspace_create_layout() {
    workspace_create 'example.com'
    local dir="$BAMBOO_WWW_DIR/example.com"
    assert_dir_exists "$dir" 'creates the workspace directory'
    assert_dir_exists "$dir/public_html" 'creates public_html'
    assert_dir_exists "$dir/logs" 'creates logs'
    assert_dir_exists "$dir/nginx" 'creates nginx'
    assert_file_exists "$dir/logs/access.log" 'creates access.log'
    assert_file_exists "$dir/logs/error.log" 'creates error.log'
    assert_file_exists "$dir/public_html/index.html" 'seeds a default index.html'
    assert_file_contains "$dir/public_html/index.html" 'example.com' 'the default page shows the domain'
}

test_workspace_path_helpers() {
    assert_eq "$BAMBOO_WWW_DIR/example.com" "$(workspace_dir 'example.com')" 'workspace_dir'
    assert_eq "$BAMBOO_WWW_DIR/example.com/public_html" "$(workspace_public 'example.com')" 'workspace_public'
    assert_eq "$BAMBOO_WWW_DIR/example.com/logs" "$(workspace_logs 'example.com')" 'workspace_logs'
    assert_eq "$BAMBOO_WWW_DIR/example.com/nginx/example.com.conf" "$(workspace_conf 'example.com')" 'workspace_conf'
    assert_eq "$BAMBOO_WWW_DIR/example.com/letsencrypt" "$(workspace_le 'example.com')" 'workspace_le'
    if workspace_exists 'example.com'; then fail 'workspace_exists is false before creation'; else pass 'workspace_exists is false before creation'; fi
    workspace_create 'example.com'
    if workspace_exists 'example.com'; then pass 'workspace_exists is true after creation'; else fail 'workspace_exists is true after creation'; fi
}

test_workspace_create_is_idempotent() {
    workspace_create 'example.com'
    printf 'custom content\n' >"$BAMBOO_WWW_DIR/example.com/public_html/index.html"
    printf 'log line\n' >>"$BAMBOO_WWW_DIR/example.com/logs/access.log"
    workspace_create 'example.com'
    assert_file_contains "$BAMBOO_WWW_DIR/example.com/public_html/index.html" 'custom content' 'existing content is preserved'
    assert_file_contains "$BAMBOO_WWW_DIR/example.com/logs/access.log" 'log line' 'existing logs are preserved'
}

test_workspace_remove() {
    workspace_create 'example.com'
    workspace_remove 'example.com' 0
    assert_dir_missing "$BAMBOO_WWW_DIR/example.com" 'deletes the whole tree'
}

test_workspace_remove_keep_files() {
    workspace_create 'example.com'
    printf 'site\n' >"$BAMBOO_WWW_DIR/example.com/public_html/marker.txt"
    mkdir -p "$(dirname "$(workspace_conf 'example.com')")"
    printf 'server {}\n' >"$(workspace_conf 'example.com')"
    ln -sfn "$BAMBOO_LETSENCRYPT_LIVE/example.com" "$(workspace_le 'example.com')"
    workspace_remove 'example.com' 1
    assert_file_exists "$BAMBOO_WWW_DIR/example.com/public_html/marker.txt" 'keeps site content'
    assert_file_exists "$BAMBOO_WWW_DIR/example.com/logs/access.log" 'keeps logs'
    assert_file_missing "$(workspace_conf 'example.com')" 'removes the generated nginx config'
    assert_file_missing "$(workspace_le 'example.com')" 'removes the letsencrypt symlink'
}

test_workspace_list_domains() {
    workspace_create 'b.example.com'
    printf 'server {}\n' >"$(workspace_conf 'b.example.com')"
    workspace_create 'a.example.com'
    printf 'server {}\n' >"$(workspace_conf 'a.example.com')"
    mkdir -p "$BAMBOO_WWW_DIR/orphan.example.com/nginx"
    mkdir -p "$BAMBOO_WWW_DIR/not-a-domain/nginx"
    local list
    list="$(workspace_list_domains | tr '\n' ' ')"
    assert_eq 'a.example.com b.example.com ' "$list" 'lists managed domains only, sorted'
}

test_workspace_list_domains_empty() {
    assert_eq '' "$(workspace_list_domains)" 'prints nothing when nothing is managed'
}
