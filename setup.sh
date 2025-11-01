#!/bin/bash
set -eou pipefail
IFS=$'\n\t'

source "$(dirname "${BASH_SOURCE[0]}")/src/common.sh"

main() {
    # Display arts title
    local arts_title_file="$(dirname "${BASH_SOURCE[0]}")/art.txt"
    if [ -f "$arts_title_file" ]; then
        cat "$arts_title_file"
        echo ""
    else
        log "WARNING" "arts.txt not found"
    fi

    # Parse arguments
    local domain=""
    while [[ $# -gt 0 ]]; do
        case $1 in
            --domain | -d) 
                domain="$2"
                shift 2
                ;; 
            *)
                error_exit "Unknown argument: $1"
                ;; 
        esac
    done
    if [ -z "$domain" ]; then
        error_exit "Domain name is required. Use 'sudo ./setup.sh --domain|-d <your_domain>'"
    fi

    # Run setup steps
    check_permission
    install_dependencies
    setup_sf_database
    setup_sf_server "$USER_NAME"
    configure_uwsgi
    setup_nginx "$domain"
}

main "$@"