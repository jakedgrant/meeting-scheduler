// Plan limits as described to the user, read from the shared fixture the
// database tests check create_poll against. The server still sets each poll's
// limits; these values only describe plans.
import fixture from '../../../../packages/shared-config/entitlements.json'

export type PaidEntitlement = keyof typeof fixture.entitlements

export const PRO_ENTITLEMENT = 'pro_access' satisfies PaidEntitlement
export const TEAM_ENTITLEMENT = 'team_access' satisfies PaidEntitlement
const EVENT_PASS = 'event_pass' satisfies keyof typeof fixture

// The fixture calls the free tier free_tier; create_poll reports it as 'free'.
export type CreationEntitlement = 'free' | PaidEntitlement | typeof EVENT_PASS

export const proParticipantLimit = fixture.entitlements.pro_access.limits.max_participants_per_poll
export const proHasUnlimitedActivePolls = fixture.entitlements.pro_access.limits.max_active_polls === -1
