# Meeting Scheduler GitHub Issues

## Summary
18 issues identified from handwritten improvement notes:
- **Enhancements:** 17
- **Bugs:** 1

---

## Issue 1: Move join button to top of poll details page
**Label:** enhancement

**Title:** Move join button to top of poll details page

**Description:**
As a user, I want the join button to be at the top of the poll details page, so that I can quickly join a poll without scrolling.

**Additional Context:**
Currently the join button placement may require scrolling to find it. Moving it to the top improves discoverability and reduces friction for new poll participants.

---

## Issue 2: Display share code prominently with copy functionality
**Label:** enhancement

**Title:** Display share code prominently with copy functionality

**Description:**
As a poll creator, I want to see the share code (e.g., "XYZ123") displayed clearly with an icon, so that I can easily share the poll with participants.

**Additional Context:**
The share code should be prominently displayed in the poll details view with a visual indicator (icon) to make it easy to identify and copy.

**Acceptance Criteria:**
- Share code is displayed clearly (e.g., "XYZ123")
- Visual icon/indicator next to share code
- Easy to copy/share functionality

---

## Issue 3: Require response for each time option in poll
**Label:** enhancement

**Title:** Require response for each time option in poll

**Description:**
As a poll participant, I want to be required to respond to each time option, so that the poll creator gets complete availability information from all participants.

**Additional Context:**
Currently participants may be able to skip time options. Requiring a response for each option ensures complete data for scheduling decisions.

**Acceptance Criteria:**
- All time options must have a response before submission
- Clear validation messaging if incomplete
- Cannot submit poll response without selecting an option for each time slot

---

## Issue 4: Add visual progress/result display for each time option
**Label:** enhancement

**Title:** Add visual progress/result display for each time option

**Description:**
As a poll creator, I want to see a visual display (progress bar or indicator) showing responses for each time option, so that I can quickly identify which times work best for participants.

**Additional Context:**
Visual representation of poll results helps quickly identify the most popular time slots without having to count individual responses.

**Acceptance Criteria:**
- Progress bar or visual indicator for each time option
- Shows percentage or count of responses
- Updates in real-time as responses come in

---

## Issue 5: Show which calendar events are interfering with time options
**Label:** enhancement

**Title:** Show which calendar events are interfering with time options

**Description:**
As a user, I want to see which of my calendar events conflict with each poll time option, so that I can make informed decisions about my availability.

**Additional Context:**
When viewing or responding to a poll, the app should show which existing calendar events overlap with proposed meeting times, helping users understand why certain times may not work for them.

**Acceptance Criteria:**
- Display conflicting calendar events for each time option
- Show event title and time
- Visual indicator for conflicts

---

## Issue 6: Add calendar view for poll time options
**Label:** enhancement

**Title:** Add calendar view for poll time options

**Description:**
As a user, I want to view poll time options in a calendar format, so that I can better visualize the proposed meeting times in context with my schedule.

**Additional Context:**
A calendar view provides better context for when meetings would occur and how they fit into the user's schedule.

**Acceptance Criteria:**
- Calendar view option for poll time slots
- Toggle between list and calendar view
- Clear indication of which slots are proposed times

---

## Issue 7: Move close poll button to bottom of screen
**Label:** enhancement

**Title:** Move close poll button to bottom of screen

**Description:**
As a poll creator, I want the close poll button (or create button) to be at the bottom of the screen, so that it follows standard UI patterns and prevents accidental clicks.

**Additional Context:**
Moving destructive or final actions to the bottom of the screen is a common UI pattern that prevents accidental activation and provides better user experience.

---

## Issue 8: Fix share button to provide poll link instead of just code
**Label:** bug

**Title:** Fix share button to provide poll link instead of just code

**Description:**
As a user, I want the share button to provide a direct link to the poll instead of just the share code, so that I can easily share polls via messaging or email.

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
- Recipients can access poll directly via link

---

## Issue 9: Add 'Add to Calendar' button for finalized meeting time
**Label:** enhancement

**Title:** Add 'Add to Calendar' button for finalized meeting time

**Description:**
As a poll creator, I want to add the final meeting time to my calendar directly from the poll, so that I don't have to manually create a calendar event.

**Additional Context:**
After a poll is closed and a final meeting time is determined, there should be a quick way to add this to the user's calendar.

**Acceptance Criteria:**
- "Add to Calendar" button visible when poll has final time
- Creates calendar event with meeting details
- Works with user's connected calendar

---

## Issue 10: Hide closed polls with option to view in separate screen
**Label:** enhancement

**Title:** Hide closed polls with option to view in separate screen

**Description:**
As a user, I want closed polls to be hidden from my main poll list by default, with an option to view them in a separate screen, so that I can focus on active polls.

**Additional Context:**
Closed polls clutter the main poll list. Moving them to a separate view improves focus on active polls while still keeping closed polls accessible.

**Acceptance Criteria:**
- Closed polls hidden from main list by default
- "View Closed Polls" option or separate screen
- Can toggle between active and closed polls

---

## Issue 11: Add visual indicator for polls you own
**Label:** enhancement

**Title:** Add visual indicator for polls you own

**Description:**
As a user, I want to see a visual icon or indicator on polls that I created, so that I can quickly distinguish between polls I own and polls I'm participating in.

**Additional Context:**
In the poll list view, it should be immediately obvious which polls the user created vs which they're just a participant in.

**Acceptance Criteria:**
- Icon or badge on polls created by user
- Distinct from participant-only polls
- Visible in list view

---

## Issue 12: Add earliest and latest time options to poll list display
**Label:** enhancement

**Title:** Add earliest and latest time options to poll list display

**Description:**
As a user, I want to see the earliest and latest time options for each poll in the list view, so that I can quickly understand the time range without opening each poll.

**Additional Context:**
The poll list should show key information like the time range (earliest to latest option) to help users prioritize which polls to respond to.

**Acceptance Criteria:**
- Display format: "Time option - Time option" (earliest to latest)
- Shows in poll list table
- Format is concise and readable

---

## Issue 13: Add due date field to polls
**Label:** enhancement

**Title:** Add due date field to polls

**Description:**
As a poll creator, I want to set a due date for poll responses, so that participants know when they need to respond by.

**Additional Context:**
Polls should have an optional due date that helps create urgency and ensures timely responses from participants.

**Acceptance Criteria:**
- Optional due date field when creating poll
- Due date displayed prominently on poll
- Participants can see deadline
- Possible notifications as deadline approaches

---

## Issue 14: Add sorting options for poll list
**Label:** enhancement

**Title:** Add sorting options for poll list

**Description:**
As a user, I want to sort my poll list by various criteria (earliest time option, due date, created date, poll name, response status), so that I can organize and prioritize my polls effectively.

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
- Clear indication of current sort

---

## Issue 15: Auto-join poll from share code
**Label:** enhancement

**Title:** Auto-join poll from share code

**Description:**
As a user, I want to automatically join a poll when I enter a share code, so that I can quickly start participating without extra steps.

**Additional Context:**
Streamline the poll joining process by automatically joining/loading the poll when a valid share code is entered.

**Acceptance Criteria:**
- Enter share code to access poll
- Automatically join/load poll details
- Reduce friction in poll participation

---

## Issue 16: Implement comprehensive notification system
**Label:** enhancement

**Title:** Implement comprehensive notification system

**Description:**
As a user, I want to receive notifications about poll-related events, so that I stay informed about poll updates and deadlines.

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
- Support for different notification channels (push, email, in-app)

---

## Issue 17: Determine and document upgrade/premium features
**Label:** enhancement

**Title:** Determine and document upgrade/premium features

**Description:**
As a product owner, I want to identify and document which features should be premium/upgrade features, so that we have a clear monetization strategy.

**Additional Context:**
Need to determine which features will be available in free tier vs premium tier.

**Tasks:**
- Review all features
- Identify premium feature candidates
- Define feature tiers
- Document upgrade path

---

## Issue 18: Update paywall implementation
**Label:** enhancement

**Title:** Update paywall implementation

**Description:**
As a product owner, I want to update the paywall implementation, so that it aligns with the defined premium features and provides a smooth upgrade experience.

**Additional Context:**
Once premium features are determined, the paywall needs to be updated to properly gate these features and encourage upgrades.

**Acceptance Criteria:**
- Paywall triggers for premium features
- Clear value proposition
- Smooth upgrade flow
- Proper feature gating
