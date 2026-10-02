import 'package:icarus/const/agents.dart';

/// Icarus agents by the valorant-api.com agent UUID a replay names them by.
/// A new agent is missing here until Icarus ships it; callers show those
/// players without an agent icon rather than guessing.
const Map<String, AgentType> replayAgentsById = {
  '41fb69c1-4189-7b37-f117-bcaf1e96f1bf': AgentType.astra,
  '5f8d3a7f-467b-97f3-062c-13acf203c006': AgentType.breach,
  '9f0d8ba9-4140-b941-57d3-a7ad57c6b417': AgentType.brimstone,
  '22697a3d-45bf-8dd7-4fec-84a9e28c69d7': AgentType.chamber,
  '1dbf2edd-4729-0984-3115-daa5eed44993': AgentType.clove,
  '117ed9e3-49f3-6512-3ccf-0cada7e3823b': AgentType.cypher,
  'cc8b64c8-4b25-4ff9-6e7f-37b4da43d235': AgentType.deadlock,
  'dade69b4-4f5a-8528-247b-219e5a1facd6': AgentType.fade,
  'e370fa57-4757-3604-3648-499e1f642d3f': AgentType.gekko,
  '95b78ed7-4637-86d9-7e41-71ba8c293152': AgentType.harbor,
  '0e38b510-41a8-5780-5e8f-568b2a4f2d6c': AgentType.iso,
  'add6443a-41bd-e414-f6ad-e58d267f4e95': AgentType.jett,
  '601dbbe7-43ce-be57-2a40-4abd24953621': AgentType.kayo,
  '1e58de9c-4950-5125-93e9-a0aee9f98746': AgentType.killjoy,
  '7c8a4701-4de6-9355-b254-e09bc2a34b72': AgentType.miks,
  'bb2a4828-46eb-8cd1-e765-15848195d751': AgentType.neon,
  '8e253930-4c05-31dd-1b6c-968525494517': AgentType.omen,
  'eb93336a-449b-9c1b-0a54-a891f7921d69': AgentType.pheonix,
  'f94c3b30-42be-e959-889c-5aa313dba261': AgentType.raze,
  'a3bfb853-43b2-7238-a4f1-ad90e9e46bcc': AgentType.reyna,
  '569fdd95-4d10-43ab-ca70-79becc718b46': AgentType.sage,
  '6f2a04ca-43e0-be17-7f36-b3908627744d': AgentType.skye,
  '320b2a48-4d9b-a075-30f1-1f93a9b638fa': AgentType.sova,
  'b444168c-4e35-8076-db47-ef9bf368f384': AgentType.tejo,
  '92eeef5d-43b5-1d4a-8d03-b3927a09034b': AgentType.veto,
  '707eab51-4836-f488-046a-cda6bf494859': AgentType.viper,
  'efba5359-4016-a1e5-7626-b1ae76895940': AgentType.vyse,
  'df1cb487-4902-002e-5c17-d28e83e78588': AgentType.waylay,
  '7f94d92c-4234-0a36-9646-3a87eb8b5c89': AgentType.yoru,
};

AgentType? replayAgentType(String agentId) =>
    replayAgentsById[agentId.toLowerCase()];
