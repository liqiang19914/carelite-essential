-- Fix ai_agents icon field: trim to single emoji (handle variation selector U+FE0F)
-- Length 1 = single emoji → keep
-- Length 2 with FE0F as 2nd char = emoji + variation selector → keep  
-- Length 2 without FE0F = doubled single emoji → trim to 1
-- Length > 2 = doubled emoji (possibly with variation selectors) → trim to first emoji
UPDATE ai_agents 
SET icon = LEFT(icon, 
  CASE 
    WHEN substr(icon, 2, 1) = chr(65039) THEN 2
    ELSE 1 
  END
)
WHERE char_length(icon) > 2 
   OR (char_length(icon) = 2 AND substr(icon, 2, 1) != chr(65039));