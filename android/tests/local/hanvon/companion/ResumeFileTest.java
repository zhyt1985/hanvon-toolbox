package local.hanvon.companion;
import java.io.*;
import java.nio.file.Files;
import java.util.Arrays;
final class ResumeFileTest {
    static void require(boolean value) { if (!value) throw new AssertionError(); }
    static void invalid(Runnable action) { try { action.run(); throw new AssertionError("Expected rejection"); } catch (IllegalArgumentException expected) {} }
    public static void main(String[] args) throws Exception {
        invalid(() -> ResumeFile.id("../bad")); invalid(() -> ResumeFile.id("1-1-1-1-1"));
        invalid(() -> ResumeFile.count("-1")); invalid(() -> ResumeFile.count("4294967297")); invalid(() -> ResumeFile.hash("123"));
        File file = File.createTempFile("hanvon-resume", ".part");
        try {
            byte[] first = new byte[1000]; Arrays.fill(first, (byte)3);
            try { ResumeFile.append(file, 0, 3000, 2000, new ByteArrayInputStream(first)); throw new AssertionError(); }
            catch (EOFException expected) {}
            require(file.length() == 1000);
            byte[] next = new byte[2000]; Arrays.fill(next, (byte)7);
            ResumeFile.append(file, 1000, 3000, 2000, new ByteArrayInputStream(next));
            byte[] all = Files.readAllBytes(file.toPath());
            require(all.length == 3000 && all[999] == 3 && all[1000] == 7);
            try { ResumeFile.append(file, 0, 3000, 1, new ByteArrayInputStream(first)); throw new AssertionError(); }
            catch (IllegalArgumentException expected) {}
            require(file.length() == 3000);
            try (InputStream input = new FileInputStream(file)) { require(ResumeFile.digest(input).length() == 64); }
        } finally { file.delete(); }
        System.out.println("Resume byte-offset, partial-write recovery and validation tests passed");
    }
}
