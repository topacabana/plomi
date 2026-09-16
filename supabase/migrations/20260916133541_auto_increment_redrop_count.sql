CREATE OR REPLACE FUNCTION public.increment_redrop_count()
RETURNS trigger AS $$
BEGIN
  IF NEW.status = 'redrop' AND (OLD.status IS DISTINCT FROM 'redrop') THEN
    NEW.redrop_count := COALESCE(OLD.redrop_count, 0) + 1;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_increment_redrop_count ON public.mandates;
CREATE TRIGGER trg_increment_redrop_count
  BEFORE UPDATE ON public.mandates
  FOR EACH ROW
  EXECUTE FUNCTION public.increment_redrop_count();
