
-- Re-point any existing healer conversations to the emotion agent
UPDATE conversations
SET agent_id = (SELECT id FROM ai_agents WHERE slug = 'emotion' LIMIT 1)
WHERE agent_id = (SELECT id FROM ai_agents WHERE slug = 'healer' LIMIT 1);
