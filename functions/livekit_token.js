const {onRequest} = require('firebase-functions/v2/https');
const {defineSecret} = require('firebase-functions/params');
const {AccessToken} = require('livekit-server-sdk');
const {RoomConfiguration, RoomAgentDispatch} = require('@livekit/protocol');
const {randomUUID} = require('crypto');

// LiveKit Cloud project credentials. Set with:
//   firebase functions:secrets:set LIVEKIT_API_KEY
//   firebase functions:secrets:set LIVEKIT_API_SECRET
//   firebase functions:secrets:set LIVEKIT_URL   (the wss:// project URL)
const LIVEKIT_URL = defineSecret('LIVEKIT_URL');
const LIVEKIT_API_KEY = defineSecret('LIVEKIT_API_KEY');
const LIVEKIT_API_SECRET = defineSecret('LIVEKIT_API_SECRET');

// Must match the agent's dispatch name (@server.rtc_session(agent_name=...) in backend/main.py).
const AGENT_NAME = 'ooink-pig';

/**
 * Mints a LiveKit access token for the kiosk tablet and requests dispatch of the
 * Pig agent into a fresh room. No auth — this is a public kiosk with no accounts
 * (per CLAUDE.md: the menu is public, there are no users to protect).
 *
 * GET -> { token, url, room }
 */
const getLiveKitToken = onRequest(
  {
    region: 'us-central1',
    cors: true,
    secrets: [LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET],
  },
  async (req, res) => {
    try {
      const url = LIVEKIT_URL.value();
      const roomName = `ooink-${randomUUID().slice(0, 12)}`;

      const at = new AccessToken(LIVEKIT_API_KEY.value(), LIVEKIT_API_SECRET.value(), {
        identity: `kiosk-${randomUUID().slice(0, 8)}`,
        name: 'Kiosk Tablet',
      });
      at.addGrant({
        roomJoin: true,
        room: roomName,
        canPublish: true,
        canSubscribe: true,
      });
      // Explicit dispatch: bring the named Pig agent into this room when the kiosk joins.
      at.roomConfig = new RoomConfiguration({
        agents: [new RoomAgentDispatch({agentName: AGENT_NAME})],
      });

      const token = await at.toJwt();
      res.status(200).json({token, url, room: roomName});
    } catch (err) {
      console.error('getLiveKitToken failed', err);
      res.status(500).json({error: 'Failed to mint LiveKit token'});
    }
  },
);

module.exports = {getLiveKitToken};
