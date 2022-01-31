#! /usr/bin/env bash

# Colors
ERROR_COLOR="\e[31m"
WARNING_COLOR="\e[33m"
SUCCESS_COLOR="\e[32m"
RUN_COLOR="\e[36m"
TITLE_COLOR="\e[95m"
END_COLOR="\e[0m"

CLEAR_LAST_LINE="\e[1A\e[K"

# Messages
GET_PR_LIST_MESSAGE="get pr list"
FETCH_DATA_MESSAGE="fetch updates"
PUSH_CHANGES_MESSAGE="push changes"

# Hashmap for bash
# Set value: declare "array_$index=$value"
# Get value: getHashMapValue arrayName hash
getHashMapValue() { 
    local array=$1 index=$2
    local i="${array}_$index"
    printf '%s' "${!i}"
}

getBaseBranch() {
    local pr_number=$1
    curl -s -H "Accept: application/vnd.github.v3+json" \
        $GH_PR_UPDATE_API/repos/$GH_PR_UPDATE_REPO/pulls/$pr_number \
        | jq .base.ref \
        | tr -d '"'
}

printTitle() {
    echo -e $(printf "${TITLE_COLOR}$@${END_COLOR}")
}

printWarning() {
    echo -e $(printf "${WARNING_COLOR}[WARNING]${END_COLOR} $@")
}

printError() {
    echo -e $(printf "${ERROR_COLOR}[ERROR]${END_COLOR} $@")
}

printRunLog() {
    echo -e $(printf "${RUN_COLOR}[RUN]${END_COLOR} $@")
}

printErrorStatus() {
    local description=$1
    local errorMessage=$2

    echo -e $(printf "${CLEAR_LAST_LINE}${RUN_COLOR}[RUN]${END_COLOR} $description ${ERROR_COLOR}ERROR${END_COLOR}")
    
    if [[ ! -z "$errorMessage" ]]; then
        printf "\n$errorMessage\n\n"
    fi
}

printSuccessStatus() {
    echo -e $(printf "${CLEAR_LAST_LINE}${RUN_COLOR}[RUN]${END_COLOR} $@ ${SUCCESS_COLOR}OK${END_COLOR}")
}

logResult() {
    local status=$1
    local description=$2
    local errorMessage=$3

    if [ $status -ne 0 ]; then
        printErrorStatus "$2"

        if [[ ! -z "$errorMessage" ]]; then
            printf "\n$errorMessage\n\n"
        fi

        exit 0
    else
        printSuccessStatus "$2"
    fi
}

containsElement () {
  local e match="$1"
  shift
  for e; do [[ "$e" == "$match" ]] && return 0; done
  return 1
}

current_branch_name=$(git rev-parse --abbrev-ref HEAD)

#
# Check uncommited files
#
git_status=$(git status --porcelain)

if [[ $git_status ]]; then
    printWarning "has uncommited files:"
    echo "$git_status"
    exit 0
fi

#
# Get PR list
#
printRunLog "$GET_PR_LIST_MESSAGE"
pr_desriptions=$(gh pr list -a @me)
logResult $? "$GET_PR_LIST_MESSAGE"

#
# Select branches for update
#
selected_pr_descriptions=$(printf "Merge master in all\n$pr_desriptions" | fzf -m)

if [[ -z $selected_pr_descriptions ]]; then
    exit 0
fi

if [[ $selected_pr_descriptions == *"Merge master in all"* ]]; then
    selected_pr_descriptions=$pr_desriptions
fi

pr_branches_list=( $(echo "$selected_pr_descriptions" | cut -f3 | xargs) )
pr_numbers_list=( $(echo "$selected_pr_descriptions" | cut -f1 | xargs) )
pr_branches_length="${#pr_branches_list[@]}"

#
# Fetch git remote data
#
printRunLog "$FETCH_DATA_MESSAGE"
errorMessage=$(git fetch 2>&1)
logResult $? "$FETCH_DATA_MESSAGE" $errorMessage

#
# Update branches
#
branches_with_conflict=()
not_found_base_branch=()

let i=0

while [[ ! -z ${pr_branches_list[$i]} ]]; do
    let progress=$i+1
    branch_name="${pr_branches_list[$i]}"
    pr_number="${pr_numbers_list[$i]}"

    base_branch=$(getBaseBranch $pr_number)

    (( i++ ))

    #
    # Skip update branch if base brach had conflicts
    #
    containsElement "$base_branch" "${branches_with_conflict[@]}"
    isBaseBranchHasConflict=$?

    if [[ "$isBaseBranchHasConflict" -eq 0 ]]; then
        printTitle "Process $branch_name"

        branches_with_conflict+=("$branch_name")

        printWarning "Base branch has conflict. Update unavailable."
        continue
    fi

    #
    # Push in stack if base branch not updated
    #
    if [[ $base_branch != "master" ]]; then
        base_pr_number=$(echo "$pr_desriptions" | grep $base_branch | cut -f1)

        if [[ $(getHashMapValue updatedPr $base_pr_number) == "true" ]]; then
            declare "updatedPr_$pr_number=true"
        elif [[ -z "$base_pr_number" ]]; then
            not_found_base_branch+=("$base_branch")
        else
            pr_branches_list+=("$branch_name")
            pr_numbers_list+=("$pr_number")
            continue
        fi
    else
        declare "updatedPr_$pr_number=true"
    fi

    CHECKOUT_BRANCH_MESSAGE="checkout to $branch_name"
    MERGE_BRANCH_MESSAGE="merge branch origin/$base_branch to $branch_name"

    printTitle "Process $branch_name"

    printRunLog "$CHECKOUT_BRANCH_MESSAGE"
    errorMessage=$(git checkout $branch_name 2>&1)
    status=$?

    if [ $status -ne 0 ]; then
        printErrorStatus "$CHECKOUT_BRANCH_MESSAGE" "$errorMessage"
        continue
    else
        printSuccessStatus "$CHECKOUT_BRANCH_MESSAGE"
    fi

    printRunLog "$MERGE_BRANCH_MESSAGE"
    errorMessage=$(git merge --no-ff --no-edit "origin/$base_branch" 2>&1)
    status=$?

    conflicts=$(git ls-files -u | wc -l)

    if [ "$conflicts" -gt 0 ] ; then
        printErrorStatus "$MERGE_BRANCH_MESSAGE"
        printError "there is a merge conflict. Aborting"

        git merge --abort

        branches_with_conflict+=("$branch_name")

        continue
    elif [ $status -ne 0 ]; then
        printErrorStatus "$MERGE_BRANCH_MESSAGE" "$errorMessage"
        continue
    else
        printSuccessStatus "$MERGE_BRANCH_MESSAGE"
    fi

    printRunLog "$PUSH_CHANGES_MESSAGE"
    errorMessage=$(git push --no-verify 2>&1)
    logResult $? "$PUSH_CHANGES_MESSAGE" $errorMessage
done

#
# Checkout to current branch
#
CHECKOUT_CURRENT_BRANCH_MESSAGE="checkout to $current_branch_name"

printRunLog "$CHECKOUT_CURRENT_BRANCH_MESSAGE"
errorMessage=$(git checkout $current_branch_name 2>&1)
logResult $? "$CHECKOUT_CURRENT_BRANCH_MESSAGE" $errorMessage

#
# Log result updates
#
echo -en '\n'

if [ ${#branches_with_conflict[@]} -eq 0 ] && [ ${#not_found_base_branch[@]} -eq 0 ]; then
    printSuccessStatus "All branches update"
else
    if [ ${#branches_with_conflict[@]} -ne 0 ]; then
        printWarning "Found branches with conflicts:"
        printf '%s\n' "${branches_with_conflict[@]}"
        printf '%s\n' "${branches_with_conflict[@]}" > ~/.git_conflict_branches
    fi

    if [ ${#not_found_base_branch[@]} -ne 0 ]; then
        printWarning "Not found base branches in update branch list:"
        printf '%s\n' "${not_found_base_branch[@]}"
    fi

fi
