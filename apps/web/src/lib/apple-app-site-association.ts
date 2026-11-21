// The file iOS downloads to decide which links on this site open the Meetful app.
// Apple's CDN fetches it from /.well-known/apple-app-site-association when the app is
// installed and refreshes it periodically, so a change here reaches devices only after
// the web is deployed and that cache expires.

/** `<team ID>.<bundle ID>` of the iOS app, from its Xcode project. */
export const IOS_APP_ID = 'PWBLH7P4Y4.com.jacobgrant.MeetingScheduler'

/**
 * A poll page, `/polls/<UUID>`: exactly 36 characters in the UUID's 8-4-4-4-12 shape, so
 * `/polls`, `/polls/new` and the per-time pages under a poll stay on the web.
 */
export const POLL_PATH_PATTERN = '/polls/????????-????-????-????-????????????'

export const appleAppSiteAssociation = {
	applinks: {
		details: [
			{
				appIDs: [IOS_APP_ID],
				components: [{ '/': POLL_PATH_PATTERN, comment: 'Opens the poll in the app.' }]
			}
		]
	}
}
