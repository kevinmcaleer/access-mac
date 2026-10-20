// Opens databases edited by the Swift engine with Jackcess and checks that
// rows, row counts and indexes read back consistently, then makes a further
// edit with Jackcess to show the file's page maps are still usable.
//
//   java -cp "/path/to/jars/*" Tools/FixtureGen/VerifyEdits.java edited-*.accdb

import com.healthmarketscience.jackcess.*;
import com.healthmarketscience.jackcess.impl.*;
import java.io.File;
import java.lang.reflect.Method;
import java.nio.file.*;
import java.util.*;

public class VerifyEdits {
  public static void main(String[] args) throws Exception {
    int failures = 0;
    for (String path : args) {
      File copy = File.createTempFile("verify", path.endsWith(".mdb") ? ".mdb" : ".accdb");
      copy.deleteOnExit();
      Files.copy(Paths.get(path), copy.toPath(), StandardCopyOption.REPLACE_EXISTING);
      try (Database db = new DatabaseBuilder(copy).open()) {
        for (String name : db.getTableNames()) {
          Table table = db.getTable(name);
          int rows = 0;
          for (Row row : table) { rows++; }
          if (rows != table.getRowCount()) {
            System.out.println("FAIL " + path + " " + name + ": " + rows + " rows but count says " + table.getRowCount());
            failures++;
          }
          for (Index index : table.getIndexes()) {
            IndexData data = ((IndexImpl) index).getIndexData();
            Method validate = IndexData.class.getDeclaredMethod("validate", boolean.class);
            validate.setAccessible(true);
            validate.invoke(data, true);
            int entries = 0;
            for (Row row : CursorBuilder.createCursor(index)) { entries++; }
            if (entries != rows) {
              System.out.println("FAIL " + path + " " + name + "/" + index.getName() + ": " + entries + " entries, " + rows + " rows");
              failures++;
            }
          }
          System.out.println("ok " + path + " " + name + " rows=" + rows);
        }
        // A further edit by Jackcess must work on top of ours.
        Table many = db.getTable("ManyRows");
        if (many == null) continue;
        many.addRow(Column.AUTO_NUMBER, "added by Jackcess", 42);
        Table all = db.getTable("AllTypes");
        for (Row row : all) {
          Object memo = row.get("MemoField");
          Object ole = row.get("OleField");
          if (memo instanceof String && ((String) memo).length() > 1000 || ole != null) {
            System.out.println("   AllTypes ID " + row.get("ID") + ": memo " + (memo == null ? 0 : ((String) memo).length())
                + " chars, ole " + (ole == null ? 0 : ((byte[]) ole).length) + " bytes, text " + row.get("TextField"));
          }
        }
      } catch (Exception e) {
        System.out.println("FAIL " + path + ": " + e);
        e.printStackTrace(System.out);
        failures++;
        continue;
      }
      try (Database db = new DatabaseBuilder(copy).setReadOnly(true).open()) {
        Table many = db.getTable("ManyRows");
        Row last = null;
        for (Row row : many) { last = row; }
        System.out.println("   after Jackcess edit: ManyRows last = " + last.get("Name") + ", count " + many.getRowCount());
      }
    }
    System.out.println(failures == 0 ? "ALL OK" : failures + " FAILURES");
    System.exit(failures == 0 ? 0 : 1);
  }
}
