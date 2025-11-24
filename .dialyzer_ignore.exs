[
  # Runtime guard and pattern coverage warnings in tool runtime flow
  ~r/lib\/ash_agent_tools\/runtime\.ex.*guard clause can never succeed/,
  ~r/lib\/ash_agent_tools\/runtime\.ex.*pattern .* can never match/,
  # Stream functions properly exported from AshAgent.Extension - ignore PLT cache issues
  ~r/lib\/ash_agent_tools\/runtime\.ex.*Call to missing or private function AshAgent\.Extension\.stream_to_structs\/2/,
  # RuntimeRegistry functions properly exported from AshAgent - ignore PLT cache issues
  ~r/lib\/ash_agent_tools\/application\.ex.*Call to missing or private function AshAgent\.RuntimeRegistry\.register_context_module\/1/
]
