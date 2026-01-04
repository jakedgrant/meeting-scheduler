-- ============================================
-- Fix RLS policies to allow participants to view closed polls
-- ============================================
-- Problem: Participants can't see polls after they're closed
-- Solution: Create a helper function to check participation without recursion

-- Helper function to check if a user is a participant in a poll
-- Using SECURITY DEFINER to bypass RLS and prevent infinite recursion
CREATE OR REPLACE FUNCTION public.is_poll_participant(poll_uuid UUID, user_uuid UUID)
RETURNS BOOLEAN AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM public.poll_participants
        WHERE poll_id = poll_uuid AND user_id = user_uuid
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Drop existing restrictive policies
DROP POLICY IF EXISTS "Anyone can view active polls" ON public.polls;
DROP POLICY IF EXISTS "Anyone can view time options for accessible polls" ON public.poll_time_options;
DROP POLICY IF EXISTS "Anyone can view participants for accessible polls" ON public.poll_participants;
DROP POLICY IF EXISTS "Anyone can view responses for accessible polls" ON public.availability_responses;

-- Polls: Allow viewing if active, creator, or participant
CREATE POLICY "Users can view accessible polls"
    ON public.polls FOR SELECT
    USING (
        status = 'active'
        OR creator_id = auth.uid()
        OR public.is_poll_participant(id, auth.uid())
    );

-- Poll Time Options: Allow viewing if poll is accessible
CREATE POLICY "Users can view time options for accessible polls"
    ON public.poll_time_options FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.polls
            WHERE polls.id = poll_time_options.poll_id
            AND (
                polls.status = 'active'
                OR polls.creator_id = auth.uid()
                OR public.is_poll_participant(polls.id, auth.uid())
            )
        )
    );

-- Poll Participants: Allow viewing if poll is accessible
CREATE POLICY "Users can view participants for accessible polls"
    ON public.poll_participants FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.polls
            WHERE polls.id = poll_participants.poll_id
            AND (
                polls.status = 'active'
                OR polls.creator_id = auth.uid()
                OR public.is_poll_participant(polls.id, auth.uid())
            )
        )
    );

-- Availability Responses: Allow viewing if poll is accessible
CREATE POLICY "Users can view responses for accessible polls"
    ON public.availability_responses FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.poll_participants pp
            JOIN public.polls p ON p.id = pp.poll_id
            WHERE pp.id = availability_responses.participant_id
            AND (
                p.status = 'active'
                OR p.creator_id = auth.uid()
                OR public.is_poll_participant(p.id, auth.uid())
            )
        )
    );
