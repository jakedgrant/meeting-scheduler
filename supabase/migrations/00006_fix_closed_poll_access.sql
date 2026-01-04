-- ============================================
-- Fix RLS policies to allow participants to view closed polls
-- ============================================
-- Problem: Participants can't see polls after they're closed
-- Solution: Update policies to allow participants to view polls they've joined

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
        OR EXISTS (
            SELECT 1 FROM public.poll_participants
            WHERE poll_participants.poll_id = polls.id
            AND poll_participants.user_id = auth.uid()
        )
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
                OR EXISTS (
                    SELECT 1 FROM public.poll_participants
                    WHERE poll_participants.poll_id = polls.id
                    AND poll_participants.user_id = auth.uid()
                )
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
                OR EXISTS (
                    SELECT 1 FROM public.poll_participants pp
                    WHERE pp.poll_id = polls.id
                    AND pp.user_id = auth.uid()
                )
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
                OR EXISTS (
                    SELECT 1 FROM public.poll_participants pp2
                    WHERE pp2.poll_id = p.id
                    AND pp2.user_id = auth.uid()
                )
            )
        )
    );
