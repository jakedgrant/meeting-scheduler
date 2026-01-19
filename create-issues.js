#!/usr/bin/env node

/**
 * Script to create GitHub issues from meeting scheduler improvements
 */

const http = require('http');

// GitHub API configuration using local proxy
const PROXY_HOST = '127.0.0.1';
const PROXY_PORT = 56519;
const REPO_OWNER = 'jakedgrant';
const REPO_NAME = 'meeting-scheduler';

// Issues to create
const issues = [
  // Poll Details improvements
  {
    title: "Move join button to top of poll details page",
    body: `As a user, I want the join button to be at the top of the poll details page, so that I can quickly join a poll without scrolling.

**Additional Context:**
Currently the join button placement may require scrolling to find it. Moving it to the top improves discoverability and reduces friction for new poll participants.`,
    labels: ["enhancement"]
  },
  {
    title: "Display share code prominently with copy functionality",
    body: `As a poll creator, I want to see the share code (e.g., "XYZ123") displayed clearly with an icon, so that I can easily share the poll with participants.

**Additional Context:**
The share code should be prominently displayed in the poll details view with a visual indicator (icon) to make it easy to identify and copy.

**Acceptance Criteria:**
- Share code is displayed clearly (e.g., "XYZ123")
- Visual icon/indicator next to share code
- Easy to copy/share functionality`,
    labels: ["enhancement"]
  },
  {
    title: "Require response for each time option in poll",
    body: `As a poll participant, I want to be required to respond to each time option, so that the poll creator gets complete availability information from all participants.

**Additional Context:**
Currently participants may be able to skip time options. Requiring a response for each option ensures complete data for scheduling decisions.

**Acceptance Criteria:**
- All time options must have a response before submission
- Clear validation messaging if incomplete
- Cannot submit poll response without selecting an option for each time slot`,
    labels: ["enhancement"]
  },
  {
    title: "Add visual progress/result display for each time option",
    body: `As a poll creator, I want to see a visual display (progress bar or indicator) showing responses for each time option, so that I can quickly identify which times work best for participants.

**Additional Context:**
Visual representation of poll results helps quickly identify the most popular time slots without having to count individual responses.

**Acceptance Criteria:**
- Progress bar or visual indicator for each time option
- Shows percentage or count of responses
- Updates in real-time as responses come in`,
    labels: ["enhancement"]
  },
  {
    title: "Show which calendar events are interfering with time options",
    body: `As a user, I want to see which of my calendar events conflict with each poll time option, so that I can make informed decisions about my availability.

**Additional Context:**
When viewing or responding to a poll, the app should show which existing calendar events overlap with proposed meeting times, helping users understand why certain times may not work for them.

**Acceptance Criteria:**
- Display conflicting calendar events for each time option
- Show event title and time
- Visual indicator for conflicts`,
    labels: ["enhancement"]
  },
  {
    title: "Add calendar view for poll time options",
    body: `As a user, I want to view poll time options in a calendar format, so that I can better visualize the proposed meeting times in context with my schedule.

**Additional Context:**
A calendar view provides better context for when meetings would occur and how they fit into the user's schedule.

**Acceptance Criteria:**
- Calendar view option for poll time slots
- Toggle between list and calendar view
- Clear indication of which slots are proposed times`,
    labels: ["enhancement"]
  },
  {
    title: "Move close poll button to bottom of screen",
    body: `As a poll creator, I want the close poll button (or create button) to be at the bottom of the screen, so that it follows standard UI patterns and prevents accidental clicks.

**Additional Context:**
Moving destructive or final actions to the bottom of the screen is a common UI pattern that prevents accidental activation and provides better user experience.`,
    labels: ["enhancement"]
  },
  {
    title: "Fix share button to provide poll link instead of just code",
    body: `As a user, I want the share button to provide a direct link to the poll instead of just the share code, so that I can easily share polls via messaging or email.

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
- Recipients can access poll directly via link`,
    labels: ["bug"]
  },
  {
    title: "Add 'Add to Calendar' button for finalized meeting time",
    body: `As a poll creator, I want to add the final meeting time to my calendar directly from the poll, so that I don't have to manually create a calendar event.

**Additional Context:**
After a poll is closed and a final meeting time is determined, there should be a quick way to add this to the user's calendar.

**Acceptance Criteria:**
- "Add to Calendar" button visible when poll has final time
- Creates calendar event with meeting details
- Works with user's connected calendar`,
    labels: ["enhancement"]
  },

  // Poll List improvements
  {
    title: "Hide closed polls with option to view in separate screen",
    body: `As a user, I want closed polls to be hidden from my main poll list by default, with an option to view them in a separate screen, so that I can focus on active polls.

**Additional Context:**
Closed polls clutter the main poll list. Moving them to a separate view improves focus on active polls while still keeping closed polls accessible.

**Acceptance Criteria:**
- Closed polls hidden from main list by default
- "View Closed Polls" option or separate screen
- Can toggle between active and closed polls`,
    labels: ["enhancement"]
  },
  {
    title: "Add visual indicator for polls you own",
    body: `As a user, I want to see a visual icon or indicator on polls that I created, so that I can quickly distinguish between polls I own and polls I'm participating in.

**Additional Context:**
In the poll list view, it should be immediately obvious which polls the user created vs which they're just a participant in.

**Acceptance Criteria:**
- Icon or badge on polls created by user
- Distinct from participant-only polls
- Visible in list view`,
    labels: ["enhancement"]
  },
  {
    title: "Add earliest and latest time options to poll list display",
    body: `As a user, I want to see the earliest and latest time options for each poll in the list view, so that I can quickly understand the time range without opening each poll.

**Additional Context:**
The poll list should show key information like the time range (earliest to latest option) to help users prioritize which polls to respond to.

**Acceptance Criteria:**
- Display format: "Time option - Time option" (earliest to latest)
- Shows in poll list table
- Format is concise and readable`,
    labels: ["enhancement"]
  },
  {
    title: "Add due date field to polls",
    body: `As a poll creator, I want to set a due date for poll responses, so that participants know when they need to respond by.

**Additional Context:**
Polls should have an optional due date that helps create urgency and ensures timely responses from participants.

**Acceptance Criteria:**
- Optional due date field when creating poll
- Due date displayed prominently on poll
- Participants can see deadline
- Possible notifications as deadline approaches`,
    labels: ["enhancement"]
  },
  {
    title: "Add sorting options for poll list",
    body: `As a user, I want to sort my poll list by various criteria (earliest time option, due date, created date, poll name, response status), so that I can organize and prioritize my polls effectively.

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
- Clear indication of current sort`,
    labels: ["enhancement"]
  },
  {
    title: "Auto-join poll from share code",
    body: `As a user, I want to automatically join a poll when I enter a share code, so that I can quickly start participating without extra steps.

**Additional Context:**
Streamline the poll joining process by automatically joining/loading the poll when a valid share code is entered.

**Acceptance Criteria:**
- Enter share code to access poll
- Automatically join/load poll details
- Reduce friction in poll participation`,
    labels: ["enhancement"]
  },
  {
    title: "Implement comprehensive notification system",
    body: `As a user, I want to receive notifications about poll-related events, so that I stay informed about poll updates and deadlines.

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
- Support for different notification channels (push, email, in-app)`,
    labels: ["enhancement"]
  },
  {
    title: "Determine and document upgrade/premium features",
    body: `As a product owner, I want to identify and document which features should be premium/upgrade features, so that we have a clear monetization strategy.

**Additional Context:**
Need to determine which features will be available in free tier vs premium tier.

**Tasks:**
- Review all features
- Identify premium feature candidates
- Define feature tiers
- Document upgrade path`,
    labels: ["enhancement"]
  },
  {
    title: "Update paywall implementation",
    body: `As a product owner, I want to update the paywall implementation, so that it aligns with the defined premium features and provides a smooth upgrade experience.

**Additional Context:**
Once premium features are determined, the paywall needs to be updated to properly gate these features and encourage upgrades.

**Acceptance Criteria:**
- Paywall triggers for premium features
- Clear value proposition
- Smooth upgrade flow
- Proper feature gating`,
    labels: ["enhancement"]
  }
];

/**
 * Make HTTP request using the local proxy
 */
function makeRequest(path, method, data) {
  return new Promise((resolve, reject) => {
    const postData = data ? JSON.stringify(data) : '';

    const options = {
      hostname: PROXY_HOST,
      port: PROXY_PORT,
      path: path,
      method: method,
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(postData),
        'User-Agent': 'Meeting-Scheduler-Issues-Script'
      }
    };

    const req = http.request(options, (res) => {
      let responseData = '';

      res.on('data', (chunk) => {
        responseData += chunk;
      });

      res.on('end', () => {
        if (res.statusCode >= 200 && res.statusCode < 300) {
          try {
            resolve(JSON.parse(responseData));
          } catch (e) {
            resolve(responseData);
          }
        } else {
          reject(new Error(`HTTP ${res.statusCode}: ${responseData}`));
        }
      });
    });

    req.on('error', (error) => {
      reject(error);
    });

    if (postData) {
      req.write(postData);
    }

    req.end();
  });
}

/**
 * Create a single issue
 */
async function createIssue(issue) {
  const paths = [
    `/github/repos/${REPO_OWNER}/${REPO_NAME}/issues`,
    `/api/repos/${REPO_OWNER}/${REPO_NAME}/issues`,
    `/repos/${REPO_OWNER}/${REPO_NAME}/issues`,
  ];

  for (const path of paths) {
    try {
      console.log(`Attempting to create issue with path: ${path}`);
      const result = await makeRequest(path, 'POST', {
        title: issue.title,
        body: issue.body,
        labels: issue.labels
      });
      return result;
    } catch (error) {
      console.log(`Failed with path ${path}: ${error.message}`);
    }
  }

  throw new Error('All API paths failed');
}

/**
 * Main execution
 */
async function main() {
  console.log(`Creating ${issues.length} GitHub issues for ${REPO_OWNER}/${REPO_NAME}...\n`);

  for (let i = 0; i < issues.length; i++) {
    const issue = issues[i];
    console.log(`[${i + 1}/${issues.length}] Creating: ${issue.title}`);

    try {
      const result = await createIssue(issue);
      console.log(`✓ Created issue #${result.number || '?'}: ${issue.title}\n`);
    } catch (error) {
      console.error(`✗ Failed to create issue: ${issue.title}`);
      console.error(`  Error: ${error.message}\n`);
    }

    // Add a small delay between requests
    await new Promise(resolve => setTimeout(resolve, 500));
  }

  console.log('Done!');
}

// Run if executed directly
if (require.main === module) {
  main().catch(error => {
    console.error('Fatal error:', error);
    process.exit(1);
  });
}

module.exports = { issues };
