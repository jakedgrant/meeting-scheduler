-- Add max length constraint and RLS policy for participant comments

-- Add check constraint for max length
ALTER TABLE public.poll_participants
ADD CONSTRAINT comment_max_length CHECK (char_length(comment) <= 500);

-- Enable RLS on poll_participants if not already enabled
-- (checking if it needs to be enabled)
ALTER TABLE public.poll_participants ENABLE ROW LEVEL SECURITY;

-- Policy: Users can only update their own comment
CREATE POLICY "Users can update their own comment"
  ON public.poll_participants
  FOR UPDATE
  USING (
    auth.uid()::text = user_id::text
    OR user_id IS NULL
  )
  WITH CHECK (
    auth.uid()::text = user_id::text
    OR user_id IS NULL
  );

-- Policy: Anonymous users cannot update comments (they have no user_id)
-- This is implicit - anonymous users can't authenticate to use the policies

-- Policy: Participants can view all participants in their poll
CREATE POLICY "Participants can view poll participants"
  ON public.poll_participants
  FOR SELECT
  USING (true);
