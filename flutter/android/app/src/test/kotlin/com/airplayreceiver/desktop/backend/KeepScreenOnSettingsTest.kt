package com.airplayreceiver.desktop.backend

import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class KeepScreenOnSettingsTest {
    @Test
    fun legacySettingsDefaultOnAndExplicitChoiceSurvivesOtherEdits() = runBlocking {
        val directory = Files.createTempDirectory("fusionplay-screen-on-")
        val path = directory.resolve("settings.json")
        try {
            val store = SettingsStore(path)
            assertTrue(store.load().keepScreenOnWhilePlaying)
            Files.write(path, """{"schemaVersion":8,"receiverName":"Living room"}""".toByteArray())
            assertTrue(store.load().keepScreenOnWhilePlaying)
            store.update { it.copy(keepScreenOnWhilePlaying = false) }
            store.update { it.copy(receiverName = "TV") }
            assertFalse(SettingsStore(path).load().keepScreenOnWhilePlaying)
            store.update { it.copy(keepScreenOnWhilePlaying = true) }
            assertTrue(SettingsStore(path).load().keepScreenOnWhilePlaying)
        } finally {
            Files.deleteIfExists(path)
            Files.deleteIfExists(directory)
        }
    }
}
