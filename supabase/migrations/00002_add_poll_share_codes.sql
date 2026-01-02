-- Add share_code column to polls table
ALTER TABLE polls ADD COLUMN share_code TEXT UNIQUE;

-- Create index for faster lookups
CREATE INDEX idx_polls_share_code ON polls(share_code);

-- Function to generate a random 6-character alphanumeric code
CREATE OR REPLACE FUNCTION generate_share_code()
RETURNS TEXT AS $$
DECLARE
    chars TEXT := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; -- Exclude similar looking chars (I, O, 0, 1, L)
    result TEXT := '';
    i INTEGER;
BEGIN
    -- Generate 6 random characters
    FOR i IN 1..6 LOOP
        result := result || substr(chars, floor(random() * length(chars) + 1)::int, 1);
    END LOOP;
    RETURN result;
END;
$$ LANGUAGE plpgsql;

-- Function to generate a unique share code
CREATE OR REPLACE FUNCTION generate_unique_share_code()
RETURNS TEXT AS $$
DECLARE
    new_code TEXT;
    code_exists BOOLEAN;
BEGIN
    LOOP
        new_code := generate_share_code();

        -- Check if code already exists
        SELECT EXISTS(SELECT 1 FROM polls WHERE share_code = new_code) INTO code_exists;

        -- If code is unique, exit loop
        IF NOT code_exists THEN
            EXIT;
        END IF;
    END LOOP;

    RETURN new_code;
END;
$$ LANGUAGE plpgsql;

-- Trigger to automatically generate share_code on poll creation
CREATE OR REPLACE FUNCTION set_poll_share_code()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.share_code IS NULL THEN
        NEW.share_code := generate_unique_share_code();
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_set_poll_share_code
BEFORE INSERT ON polls
FOR EACH ROW
EXECUTE FUNCTION set_poll_share_code();

-- Update existing polls with unique share codes
DO $$
DECLARE
    poll_record RECORD;
BEGIN
    FOR poll_record IN SELECT id FROM polls WHERE share_code IS NULL LOOP
        UPDATE polls
        SET share_code = generate_unique_share_code()
        WHERE id = poll_record.id;
    END LOOP;
END $$;

-- Make share_code NOT NULL after populating existing records
ALTER TABLE polls ALTER COLUMN share_code SET NOT NULL;

-- Add helper function to find poll by code
CREATE OR REPLACE FUNCTION get_poll_by_code(code TEXT)
RETURNS TABLE (
    id UUID,
    title TEXT,
    description TEXT,
    location TEXT,
    status poll_status,
    creator_id UUID,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    share_code TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT p.id, p.title, p.description, p.location, p.status,
           p.creator_id, p.created_at, p.updated_at, p.share_code
    FROM polls p
    WHERE p.share_code = UPPER(code);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Grant execute permission
GRANT EXECUTE ON FUNCTION get_poll_by_code(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION get_poll_by_code(TEXT) TO anon;
