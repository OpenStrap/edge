package wtf.openstrap.openstrap_edge

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The watchdog, CDM and boot paths start the tracking service from the
 * background. On Android 14+ with "Nearby devices" revoked, startForeground
 * with the connectedDevice type throws, and a startForegroundService that never
 * reaches the foreground kills the process at its deadline. The start must be
 * refused up front in that state.
 */
class ConnectedDeviceTypeAllowedTest {
    private val connect = "android.permission.BLUETOOTH_CONNECT"
    private val scan = "android.permission.BLUETOOTH_SCAN"

    @Test
    fun android14WithoutBluetoothPermissionIsRefused() {
        assertFalse(EdgeTrackingService.connectedDeviceTypeAllowed(34) { false })
        assertFalse(EdgeTrackingService.connectedDeviceTypeAllowed(36) { false })
    }

    @Test
    fun android14WithEitherBluetoothPermissionIsAllowed() {
        assertTrue(EdgeTrackingService.connectedDeviceTypeAllowed(34) { it == connect })
        assertTrue(EdgeTrackingService.connectedDeviceTypeAllowed(34) { it == scan })
    }

    @Test
    fun olderReleasesHaveNoTypePrerequisite() {
        assertTrue(EdgeTrackingService.connectedDeviceTypeAllowed(33) { false })
        assertTrue(EdgeTrackingService.connectedDeviceTypeAllowed(26) { false })
    }
}
