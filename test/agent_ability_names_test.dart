import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';

void main() {
  // Each name follows the icon and shape Icarus draws at that index, which
  // for Phoenix, Deadlock, Vyse and Miks is not the game's C Q E X order.
  test('agent abilities are named for what each index draws', () {
    final expectedNames = <AgentType, List<String>>{
      AgentType.jett: ['Cloudburst', 'Updraft', 'Tailwind', 'Blade Storm'],
      AgentType.raze: ['Boom Bot', 'Blast Pack', 'Paint Shells', 'Showstopper'],
      AgentType.pheonix: ['Blaze', 'Curveball', 'Hot Hands', 'Run it Back'],
      AgentType.astra: [
        'Gravity Well',
        'Nova Pulse',
        'Nebula/Dissipate',
        'Cosmic Divide',
        'Astra Star',
      ],
      AgentType.clove: ['Pick-me-up', 'Meddle', 'Ruse', 'Not Dead Yet'],
      AgentType.breach: [
        'Aftershock',
        'Flashpoint',
        'Fault Line',
        'Rolling Thunder',
      ],
      AgentType.iso: ['Contingency', 'Undercut', 'Double Tap', 'Kill Contract'],
      AgentType.viper: [
        'Snake Bite',
        'Poison Cloud',
        'Toxic Screen',
        "Viper's Pit",
      ],
      AgentType.deadlock: [
        'GravNet',
        'Sonic Sensor',
        'Barrier Mesh',
        'Annihilation',
      ],
      AgentType.yoru: [
        'Fakeout',
        'Blindside',
        'Gatecrash',
        'Dimensional Drift',
      ],
      AgentType.sova: [
        'Owl Drone',
        'Shock Bolt',
        'Recon Bolt',
        "Hunter's Fury",
      ],
      AgentType.skye: ['Regrowth', 'Trailblazer', 'Guiding Light', 'Seekers'],
      AgentType.kayo: ['FRAG/ment', 'FLASH/drive', 'ZERO/point', 'NULL/cmd'],
      AgentType.killjoy: ['Nanoswarm', 'Alarmbot', 'Turret', 'Lockdown'],
      AgentType.brimstone: [
        'Stim Beacon',
        'Incendiary',
        'Sky Smoke',
        'Orbital Strike',
      ],
      AgentType.cypher: ['Trapwire', 'Cyber Cage', 'Spycam', 'Neural Theft'],
      AgentType.chamber: [
        'Trademark',
        'Headhunter',
        'Rendezvous',
        'Tour De Force',
      ],
      AgentType.fade: ['Prowler', 'Seize', 'Haunt', 'Nightfall'],
      AgentType.gekko: ['Mosh Pit', 'Wingman', 'Dizzy', 'Thrash'],
      AgentType.harbor: ['Storm Surge', 'High Tide', 'Cove', 'Reckoning'],
      AgentType.neon: ['Fast Lane', 'Relay Bolt', 'High Gear', 'Overdrive'],
      AgentType.omen: [
        'Shrouded Step',
        'Paranoia',
        'Dark Cover',
        'From the Shadows',
      ],
      AgentType.reyna: ['Leer', 'Devour', 'Dismiss', 'Empress'],
      AgentType.sage: [
        'Barrier Orb',
        'Slow Orb',
        'Healing Orb',
        'Resurrection',
      ],
      AgentType.vyse: ['Shear', 'Razorvine', 'Arc Rose', 'Steel Garden'],
      AgentType.tejo: [
        'Stealth Drone',
        'Special Delivery',
        'Guided Salvo',
        'Armageddon',
      ],
      AgentType.waylay: [
        'Saturate',
        'Lightspeed',
        'Refract',
        'Convergent Paths',
      ],
      AgentType.veto: ['Crosscut', 'Chokehold', 'Interceptor', 'Evolution'],
      AgentType.miks: [
        'M-pulse Concuss',
        'M-pulse Healing',
        'Waveform',
        'Harmonize',
        'Bassquake',
      ],
    };

    expect(AgentData.agents.keys.toSet(), expectedNames.keys.toSet());

    for (final entry in expectedNames.entries) {
      final agent = AgentData.agents[entry.key]!;
      expect(
        agent.abilities.map((ability) => ability.name),
        entry.value,
        reason: '${agent.name} ability names should match their icons',
      );
    }
  });
}
