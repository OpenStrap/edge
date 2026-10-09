package wtf.openstrap.openstrap_edge

import android.provider.DocumentsContract
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BackupFolderBridgeTest {
    @Test
    fun publishingRequiresWriteRenameAndDeleteSupport() {
        val flags = DocumentsContract.Document.FLAG_SUPPORTS_WRITE or
            DocumentsContract.Document.FLAG_SUPPORTS_RENAME or DocumentsContract.Document.FLAG_SUPPORTS_DELETE
        assertTrue(canPublishBackup(flags))
        for (missing in listOf(DocumentsContract.Document.FLAG_SUPPORTS_WRITE,
            DocumentsContract.Document.FLAG_SUPPORTS_RENAME, DocumentsContract.Document.FLAG_SUPPORTS_DELETE)) {
            assertFalse(canPublishBackup(flags and missing.inv()))
        }
    }

    @Test
    fun backupNamesStayWithinTheChosenDirectory() {
        requireBackupFileName("openstrap-20261007-120000.db.gz.partial")
        requireBackupFileName("openstrap-20261007-120000-2.db.gz")
        for (name in listOf("", ".", "..", "../backup", "folder/backup", "folder\\backup", "a\u0000b")) {
            var rejected = false
            try { requireBackupFileName(name) } catch (_: IllegalArgumentException) { rejected = true }
            assertTrue("must reject $name", rejected)
        }
    }
}
