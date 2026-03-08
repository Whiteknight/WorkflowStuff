#!/usr/bin/env bash

set -euo pipefail

# Global variables
TICKET_KEY=""
TICKET_SUMMARY=""
TICKET_DESCRIPTION=""
TICKET_ACCEPTANCE_CRITERIA=""
BRANCH_NAME=""

error_exit() {
    echo "ERROR: $1" >&2
    exit 1
}

check_dependencies() {
    command -v acli >/dev/null 2>&1 || error_exit "acli is required but not found in PATH. Please install Atlassian CLI."
    command -v git >/dev/null 2>&1 || error_exit "git is required but not found in PATH."
    command -v jq >/dev/null 2>&1 || error_exit "jq is required but not found in PATH."
    command -v kiro-cli >/dev/null 2>&1 || error_exit "kiro-cli is required but not found in PATH."
}

query_first_ticket() {
    local jql="$1"
    
    echo "Querying Jira with JQL: $jql"
    
    local result
    if ! result=$(acli jira issue list --jql "$jql" --limit 1 --columns key --output-format plain 2>&1); then
        error_exit "Failed to query Jira: $result"
    fi
    
    TICKET_KEY=$(echo "$result" | grep -E '^[A-Z]+-[0-9]+$' | head -n1)
    
    if [ -z "$TICKET_KEY" ]; then
        error_exit "No tickets found for JQL query: $jql"
    fi
    
    echo "Found ticket: $TICKET_KEY"
}

get_ticket_details() {
    local ticket_key="$1"
    
    echo "Retrieving details for $ticket_key"
    
    local json
    if ! json=$(acli jira issue get "$ticket_key" --output-format json 2>&1); then
        error_exit "Failed to retrieve ticket details: $json"
    fi
    
    TICKET_SUMMARY=$(echo "$json" | jq -r '.fields.summary // empty')
    TICKET_DESCRIPTION=$(echo "$json" | jq -r '.fields.description // empty')
    
    # Try to get acceptance criteria from custom field, fall back to parsing description
    TICKET_ACCEPTANCE_CRITERIA=$(echo "$json" | jq -r '.fields.customfield_10001 // empty')
    
    if [ -z "$TICKET_ACCEPTANCE_CRITERIA" ]; then
        # Try to extract from description
        TICKET_ACCEPTANCE_CRITERIA=$(echo "$TICKET_DESCRIPTION" | sed -n '/Acceptance Criteria:/,/^$/p' | tail -n +2 | sed '/^$/d')
    fi
    
    if [ -z "$TICKET_SUMMARY" ]; then
        error_exit "Failed to extract ticket summary from JSON"
    fi
    
    echo "Ticket summary: $TICKET_SUMMARY"
}

prepare_git_branch() {
    local ticket_key="$1"
    
    echo "Preparing git branch for $ticket_key"
    
    if ! git fetch origin 2>&1; then
        error_exit "Failed to fetch from origin"
    fi
    
    if ! git reset --hard origin/master 2>&1; then
        error_exit "Failed to reset to origin/master"
    fi
    
    if ! git checkout -b "$ticket_key" 2>&1; then
        error_exit "Failed to create branch $ticket_key"
    fi
    
    BRANCH_NAME="$ticket_key"
    echo "Created and checked out branch: $BRANCH_NAME"
}

create_planning_prompt() {
    local ticket_key="$1"
    local summary="$2"
    local description="$3"
    local acceptance_criteria="$4"
    
    local prompt_file=".kiro-prompt-${ticket_key}.md"
    
    cat > "$prompt_file" <<EOF
# Jira Ticket: $ticket_key

## Summary
$summary

## Description
$description
EOF
    
    if [ -n "$acceptance_criteria" ]; then
        cat >> "$prompt_file" <<EOF

## Acceptance Criteria
$acceptance_criteria
EOF
    fi
    
    echo "$prompt_file"
}

invoke_kiro_planning() {
    local prompt_file="$1"
    local ticket_key="$2"
    
    echo "Creating implementation plan with kiro-cli..."
    
    # Use ticket key as feature name for the spec
    if ! kiro-cli "Create a spec for feature ${ticket_key} based on #$prompt_file" 2>&1; then
        error_exit "kiro-cli planning failed"
    fi
    
    echo ""
    echo "Spec created at .kiro/specs/${ticket_key}/"
}

wait_for_approval() {
    echo ""
    echo "Review the spec above. Do you want to proceed with implementation?"
    read -p "Continue? (y/n): " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted by user."
        exit 0
    fi
}

invoke_kiro_execution() {
    echo "Executing implementation plan with kiro-cli..."
    
    if ! kiro-cli "run all tasks" 2>&1; then
        error_exit "kiro-cli execution failed"
    fi
}

main() {
    if [ $# -lt 1 ] || [ $# -gt 2 ]; then
        echo "Usage: $0 <JQL_QUERY>" >&2
        echo "   or: $0 --ticket <TICKET_KEY>" >&2
        exit 1
    fi
    
    check_dependencies
    
    # Check if explicit ticket key provided
    if [ "$1" = "--ticket" ]; then
        if [ $# -ne 2 ]; then
            echo "ERROR: --ticket requires a ticket key argument" >&2
            exit 1
        fi
        TICKET_KEY="$2"
        echo "Using explicit ticket: $TICKET_KEY"
    else
        local jql="$1"
        query_first_ticket "$jql"
    fi
    
    get_ticket_details "$TICKET_KEY"
    prepare_git_branch "$TICKET_KEY"
    
    local prompt_file
    prompt_file=$(create_planning_prompt "$TICKET_KEY" "$TICKET_SUMMARY" "$TICKET_DESCRIPTION" "$TICKET_ACCEPTANCE_CRITERIA")
    echo "Prompt written to $prompt_file"
    
    invoke_kiro_planning "$prompt_file" "$TICKET_KEY"
    wait_for_approval
    invoke_kiro_execution
    
    echo ""
    echo "Automation complete for ticket $TICKET_KEY on branch $BRANCH_NAME"
    echo "Review the changes and create a PR when ready."
}

main "$@"
