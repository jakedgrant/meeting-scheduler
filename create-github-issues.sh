#!/bin/bash

# Script to create GitHub issues for meeting-scheduler improvements
# Usage: ./create-github-issues.sh [GITHUB_TOKEN]
#
# If GITHUB_TOKEN is not provided, the script will look for it in:
# 1. GITHUB_TOKEN environment variable
# 2. ~/.github_token file
# 3. Will prompt for manual input

set -e

REPO_OWNER="jakedgrant"
REPO_NAME="meeting-scheduler"
GITHUB_API="https://api.github.com"

# Get GitHub token
if [ -n "$1" ]; then
    GITHUB_TOKEN="$1"
elif [ -n "$GITHUB_TOKEN" ]; then
    : # Token already in environment
elif [ -f ~/.github_token ]; then
    GITHUB_TOKEN=$(cat ~/.github_token)
else
    echo "Error: GitHub token not found!"
    echo "Please provide token as argument or set GITHUB_TOKEN environment variable"
    echo "Usage: $0 [GITHUB_TOKEN]"
    exit 1
fi

echo "Creating 18 GitHub issues for $REPO_OWNER/$REPO_NAME..."
echo ""

# Function to create an issue
create_issue() {
    local title="$1"
    local body="$2"
    local labels="$3"

    echo "Creating: $title"

    response=$(curl -s -w "\n%{http_code}" \
        -X POST \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "$GITHUB_API/repos/$REPO_OWNER/$REPO_NAME/issues" \
        -d "{\"title\":$(echo "$title" | jq -R -s .),\"body\":$(echo "$body" | jq -R -s .),\"labels\":[$labels]}")

    http_code=$(echo "$response" | tail -n1)
    response_body=$(echo "$response" | sed '$d')

    if [ "$http_code" -eq 201 ]; then
        issue_number=$(echo "$response_body" | jq -r '.number')
        echo "✓ Created issue #$issue_number"
    else
        echo "✗ Failed (HTTP $http_code)"
        echo "$response_body" | jq -r '.message // .' 2>/dev/null || echo "$response_body"
    fi
    echo ""

    # Small delay to avoid rate limiting
    sleep 0.5
}

# Issue 1
create_issue \
    "Move join button to top of poll details page" \
    "As a user, I want the join button to be at the top of the poll details page, so that I can quickly join a poll without scrolling.

**Additional Context:**
Currently the join button placement may require scrolling to find it. Moving it to the top improves discoverability and reduces friction for new poll participants." \
    "\"enhancement\""

# Issue 2
create_issue \
    "Display share code prominently with copy functionality" \
    "As a poll creator, I want to see the share code (e.g., \"XYZ123\") displayed clearly with an icon, so that I can easily share the poll with participants.

**Additional Context:**
The share code should be prominently displayed in the poll details view with a visual indicator (icon) to make it easy to identify and copy.

**Acceptance Criteria:**
- Share code is displayed clearly (e.g., \"XYZ123\")
- Visual icon/indicator next to share code
- Easy to copy/share functionality" \
    "\"enhancement\""

# Issue 3
create_issue \
    "Require response for each time option in poll" \
    "As a poll participant, I want to be required to respond to each time option, so that the poll creator gets complete availability information from all participants.

**Additional Context:**
Currently participants may be able to skip time options. Requiring a response for each option ensures complete data for scheduling decisions.

**Acceptance Criteria:**
- All time options must have a response before submission
- Clear validation messaging if incomplete
- Cannot submit poll response without selecting an option for each time slot" \
    "\"enhancement\""

# Issue 4
create_issue \
    "Add visual progress/result display for each time option" \
    "As a poll creator, I want to see a visual display (progress bar or indicator) showing responses for each time option, so that I can quickly identify which times work best for participants.

**Additional Context:**
Visual representation of poll results helps quickly identify the most popular time slots without having to count individual responses.

**Acceptance Criteria:**
- Progress bar or visual indicator for each time option
- Shows percentage or count of responses
- Updates in real-time as responses come in" \
    "\"enhancement\""

# Issue 5
create_issue \
    "Show which calendar events are interfering with time options" \
    "As a user, I want to see which of my calendar events conflict with each poll time option, so that I can make informed decisions about my availability.

**Additional Context:**
When viewing or responding to a poll, the app should show which existing calendar events overlap with proposed meeting times, helping users understand why certain times may not work for them.

**Acceptance Criteria:**
- Display conflicting calendar events for each time option
- Show event title and time
- Visual indicator for conflicts" \
    "\"enhancement\""

# Issue 6
create_issue \
    "Add calendar view for poll time options" \
    "As a user, I want to view poll time options in a calendar format, so that I can better visualize the proposed meeting times in context with my schedule.

**Additional Context:**
A calendar view provides better context for when meetings would occur and how they fit into the user's schedule.

**Acceptance Criteria:**
- Calendar view option for poll time slots
- Toggle between list and calendar view
- Clear indication of which slots are proposed times" \
    "\"enhancement\""

# Issue 7
create_issue \
    "Move close poll button to bottom of screen" \
    "As a poll creator, I want the close poll button (or create button) to be at the bottom of the screen, so that it follows standard UI patterns and prevents accidental clicks.

**Additional Context:**
Moving destructive or final actions to the bottom of the screen is a common UI pattern that prevents accidental activation and provides better user experience." \
    "\"enhancement\""

# Issue 8
create_issue \
    "Fix share button to provide poll link instead of just code" \
    "As a user, I want the share button to provide a direct link to the poll instead of just the share code, so that I can easily share polls via messaging or email.

**Additional Context:**
Currently when sharing polls via the share button, users may only get the code. The share button should provide a full link to the poll that recipients can click directly.

**Steps to Reproduce:**
1. Create or view a poll
2. Click share button
3. Observe that only code is shown/shared

**Expected Behavior:**
Share button should give a full URL link to the poll instead of (or in addition to) the share code.

**Acceptance Criteria:**
- Share button generates full poll URL
- Link can be copied and shared
- Recipients can access poll directly via link" \
    "\"bug\""

# Issue 9
create_issue \
    "Add 'Add to Calendar' button for finalized meeting time" \
    "As a poll creator, I want to add the final meeting time to my calendar directly from the poll, so that I don't have to manually create a calendar event.

**Additional Context:**
After a poll is closed and a final meeting time is determined, there should be a quick way to add this to the user's calendar.

**Acceptance Criteria:**
- \"Add to Calendar\" button visible when poll has final time
- Creates calendar event with meeting details
- Works with user's connected calendar" \
    "\"enhancement\""

# Issue 10
create_issue \
    "Hide closed polls with option to view in separate screen" \
    "As a user, I want closed polls to be hidden from my main poll list by default, with an option to view them in a separate screen, so that I can focus on active polls.

**Additional Context:**
Closed polls clutter the main poll list. Moving them to a separate view improves focus on active polls while still keeping closed polls accessible.

**Acceptance Criteria:**
- Closed polls hidden from main list by default
- \"View Closed Polls\" option or separate screen
- Can toggle between active and closed polls" \
    "\"enhancement\""

# Issue 11
create_issue \
    "Add visual indicator for polls you own" \
    "As a user, I want to see a visual icon or indicator on polls that I created, so that I can quickly distinguish between polls I own and polls I'm participating in.

**Additional Context:**
In the poll list view, it should be immediately obvious which polls the user created vs which they're just a participant in.

**Acceptance Criteria:**
- Icon or badge on polls created by user
- Distinct from participant-only polls
- Visible in list view" \
    "\"enhancement\""

# Issue 12
create_issue \
    "Add earliest and latest time options to poll list display" \
    "As a user, I want to see the earliest and latest time options for each poll in the list view, so that I can quickly understand the time range without opening each poll.

**Additional Context:**
The poll list should show key information like the time range (earliest to latest option) to help users prioritize which polls to respond to.

**Acceptance Criteria:**
- Display format: \"Time option - Time option\" (earliest to latest)
- Shows in poll list table
- Format is concise and readable" \
    "\"enhancement\""

# Issue 13
create_issue \
    "Add due date field to polls" \
    "As a poll creator, I want to set a due date for poll responses, so that participants know when they need to respond by.

**Additional Context:**
Polls should have an optional due date that helps create urgency and ensures timely responses from participants.

**Acceptance Criteria:**
- Optional due date field when creating poll
- Due date displayed prominently on poll
- Participants can see deadline
- Possible notifications as deadline approaches" \
    "\"enhancement\""

# Issue 14
create_issue \
    "Add sorting options for poll list" \
    "As a user, I want to sort my poll list by various criteria (earliest time option, due date, created date, poll name, response status), so that I can organize and prioritize my polls effectively.

**Additional Context:**
Different sorting options help users find and prioritize polls based on their needs.

**Sorting Options:**
- Earliest time option
- Due date
- Created date
- Poll name (alphabetical)
- Response status (responded/not responded yet)

**Acceptance Criteria:**
- Dropdown or menu to select sort criteria
- Sort order persists
- Clear indication of current sort" \
    "\"enhancement\""

# Issue 15
create_issue \
    "Auto-join poll from share code" \
    "As a user, I want to automatically join a poll when I enter a share code, so that I can quickly start participating without extra steps.

**Additional Context:**
Streamline the poll joining process by automatically joining/loading the poll when a valid share code is entered.

**Acceptance Criteria:**
- Enter share code to access poll
- Automatically join/load poll details
- Reduce friction in poll participation" \
    "\"enhancement\""

# Issue 16
create_issue \
    "Implement comprehensive notification system" \
    "As a user, I want to receive notifications about poll-related events, so that I stay informed about poll updates and deadlines.

**Additional Context:**
Need a bigger/more robust notification system to handle various poll events.

**Notification Events:**
- New poll invitations
- Poll responses received (for creators)
- Poll closing soon (approaching due date)
- Poll closed and final time selected
- Poll updates

**Acceptance Criteria:**
- Notification preferences configurable
- Timely delivery of notifications
- Clear, actionable notification content
- Support for different notification channels (push, email, in-app)" \
    "\"enhancement\""

# Issue 17
create_issue \
    "Determine and document upgrade/premium features" \
    "As a product owner, I want to identify and document which features should be premium/upgrade features, so that we have a clear monetization strategy.

**Additional Context:**
Need to determine which features will be available in free tier vs premium tier.

**Tasks:**
- Review all features
- Identify premium feature candidates
- Define feature tiers
- Document upgrade path" \
    "\"enhancement\""

# Issue 18
create_issue \
    "Update paywall implementation" \
    "As a product owner, I want to update the paywall implementation, so that it aligns with the defined premium features and provides a smooth upgrade experience.

**Additional Context:**
Once premium features are determined, the paywall needs to be updated to properly gate these features and encourage upgrades.

**Acceptance Criteria:**
- Paywall triggers for premium features
- Clear value proposition
- Smooth upgrade flow
- Proper feature gating" \
    "\"enhancement\""

echo "Done! All issues processed."
