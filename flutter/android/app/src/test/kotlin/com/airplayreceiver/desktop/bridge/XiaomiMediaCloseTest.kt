package com.airplayreceiver.desktop.bridge

import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.*
import org.junit.Test

class XiaomiMediaCloseTest {
    private var now = 0L
    private val reducer = XiaomiPlaybackReducer { now }

    private fun event(name: String, generation: Long = 1, channel: String = "audio") =
        WindowsBridgeXiaomiEvent(name, buildJsonObject {
            put("media_generation", generation)
            put("channel", channel)
            if (name == "interconnect_stage") put("stage", "media_session_established")
            if (name == "playback_state") {
                put("session_active", true)
                put("raw_state", 2)
            }
        }, rawJson = "{}")

    private fun start(generation: Long = 1) {
        reducer.reduce(event("interconnect_stage", generation))
        reducer.reduce(event("playback_state", generation))
    }

    @Test fun audioEofPausesImmediatelyThenEndsWithoutFurtherNotifications() {
        start()
        val close = reducer.reduce(event("media_channel_closed"))
        val pause = close.mutations.single() as XiaomiPlaybackMutation.Activate
        assertEquals(3, pause.rawState)
        assertFalse(pause.newSession)
        now = 1_999
        assertNull(reducer.expireClosedMedia())
        now = 2_000
        assertTrue(reducer.expireClosedMedia()!!.mutations.single() is XiaomiPlaybackMutation.Deactivate)
        assertNull(reducer.expireClosedMedia())
        assertTrue(reducer.reduce(event("playback_state")).mutations.isEmpty())
    }

    @Test fun newMediaRouteCancelsOldCloseAndAcceptsPlayback() {
        start()
        reducer.reduce(event("media_channel_closed"))
        now = 800
        start(2)
        now = 3_000
        assertNull(reducer.expireClosedMedia())
        assertTrue(reducer.reduce(event("media_channel_closed", 1)).mutations.isEmpty())
        val playing = reducer.reduce(event("playback_state", 2)).mutations.single() as XiaomiPlaybackMutation.Activate
        assertEquals(2, playing.rawState)
    }

    @Test fun duplicateClosesDoNotDelayCleanupAndLatePlayingDoesNotResume() {
        start()
        reducer.reduce(event("media_channel_closed"))
        now = 1_500
        assertTrue(reducer.reduce(event("playback_state")).mutations.isEmpty())
        assertTrue(reducer.reduce(event("media_channel_closed")).mutations.isEmpty())
        now = 2_000
        assertTrue(reducer.expireClosedMedia()!!.mutations.single() is XiaomiPlaybackMutation.Deactivate)
    }

    @Test fun rtspEofAlonePreservesIndependentAudioButTeardownStopsIt() {
        start()
        assertTrue(reducer.reduce(event("media_channel_closed", channel = "rtsp")).mutations.isEmpty())
        now = 5_000
        assertNull(reducer.expireClosedMedia())
        val stop = reducer.reduce(event("stream_stopped")).mutations.single() as XiaomiPlaybackMutation.Activate
        assertEquals(3, stop.rawState)
        now = 7_000
        assertTrue(reducer.expireClosedMedia()!!.mutations.single() is XiaomiPlaybackMutation.Deactivate)
    }

    @Test fun resetAllowsGenerationToRestartFromOne() {
        start(7)
        reducer.reduce(event("media_channel_closed", 7))
        reducer.reset()
        start(1)
        now = 3_000
        assertNull(reducer.expireClosedMedia())
        assertEquals(2, (reducer.reduce(event("playback_state")).mutations.single() as XiaomiPlaybackMutation.Activate).rawState)
    }
}
