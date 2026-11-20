package local.hanvon.companion;
import java.io.*;
import java.nio.file.*;
import java.util.*;

public final class SnapshotCaptureTest {
    static final class Source implements SnapshotCapture.Source {
        final Map<String,byte[]> files=new TreeMap<>();final Set<String> dirs=new TreeSet<>();int opens;boolean mutate,add,revoked,wal;
        public List<SnapshotCapture.Entry> list(String p){List<SnapshotCapture.Entry> out=new ArrayList<>();for(String d:dirs)if(SnapshotCapture.parent(d).equals(p))out.add(new SnapshotCapture.Entry(d,true,null,1L));for(String f:files.keySet())if(SnapshotCapture.parent(f).equals(p))out.add(new SnapshotCapture.Entry(f,false,(long)files.get(f).length,1L));return out;}
        public InputStream open(String p){opens++;byte[] bytes=files.get(p);if(mutate&&opens>1){bytes=bytes.clone();bytes[0]^=1;}if(add&&opens>files.size())files.put("note/new",new byte[1]);return new ByteArrayInputStream(bytes);}
        public void check() throws Exception {if(revoked)throw new SecurityException();}
    }
    interface Action{void run() throws Exception;}
    static void rejects(Action action,String code) throws Exception {try{action.run();throw new AssertionError("Accepted "+code);}catch(SnapshotCapture.Failure e){if(!e.code.equals(code))throw e;}}
    static Source fixture(){Source s=new Source();s.dirs.addAll(Arrays.asList("note","note/empty",".database"));s.files.put("note/page",new byte[]{1,2,3});s.files.put(".database/HvNote.db",new byte[]{4,5});s.files.put("private-unselected",new byte[]{9});return s;}
    static String hash(byte[] bytes)throws Exception{return ResumeFile.digest(new ByteArrayInputStream(bytes));}
    static void remove(File f){File[] children=f.listFiles();if(children!=null)for(File c:children)remove(c);f.delete();}
    public static void main(String[] args)throws Exception {
        File root=Files.createTempDirectory("SnapshotCaptureTest").toFile();int count=0;
        try{
            Source s=fixture();String indexHash=hash(s.files.get(".database/HvNote.db"));
            List<SnapshotCapture.Entry> result=SnapshotCapture.capture(s,"note",true,".database/HvNote.db",indexHash,root,100,0,(a,b)->{});
            if(result.size()!=5||result.stream().anyMatch(e->e.path.equals("private-unselected")))throw new AssertionError("Scope");count++;
            SnapshotCapture.Entry page=result.stream().filter(e->e.path.equals("note/page")).findFirst().get();s.files.put("note/page",new byte[]{8,8,8});
            if(!Arrays.equals(Files.readAllBytes(new File(root,page.artifact).toPath()),new byte[]{1,2,3}))throw new AssertionError("Mutable artifact");count++;
            Source changed=fixture();changed.mutate=true;rejects(()->SnapshotCapture.capture(changed,"note",true,"","",root,100,0,(a,b)->{}),"SOURCE_CHANGED");count++;
            Source added=fixture();SnapshotCapture.Source adding=new SnapshotCapture.Source(){int n;public void check(){}public InputStream open(String p){return added.open(p);}public List<SnapshotCapture.Entry> list(String p){if(++n>3)added.files.put("note/new",new byte[1]);return added.list(p);}};
            rejects(()->SnapshotCapture.capture(adding,"note",true,"","",root,100,0,(a,b)->{}),"SOURCE_CHANGED");count++;
            Source quota=fixture();rejects(()->SnapshotCapture.capture(quota,"note",true,"","",root,2,0,(a,b)->{}),"SNAPSHOT_QUOTA");if(quota.opens!=0)throw new AssertionError();count++;
            rejects(()->SnapshotCapture.capture(fixture(),"note",true,"","",root,100,Long.MAX_VALUE/2,(a,b)->{}),"SNAPSHOT_QUOTA");count++;
            Source wal=fixture();wal.files.put(".database/HvNote.db-wal",new byte[1]);rejects(()->SnapshotCapture.capture(wal,"note",true,".database/HvNote.db",indexHash,root,100,0,(a,b)->{}),"UNSTABLE_DATABASE");count++;
            rejects(()->SnapshotCapture.capture(fixture(),"note",true,".database/HvNote.db",String.join("",Collections.nCopies(64,"0")),root,100,0,(a,b)->{}),"SOURCE_CHANGED");count++;
            Source collision=fixture();collision.files.put("note/PAGE",new byte[1]);rejects(()->SnapshotCapture.capture(collision,"note",true,"","",root,100,0,(a,b)->{}),"SCOPE_LIMIT");count++;
            Source revoked=fixture();try{SnapshotCapture.capture(revoked,"note",true,"","",root,100,0,(a,b)->{revoked.revoked=true;});throw new AssertionError();}catch(SecurityException expected){}count++;
            try{SnapshotCapture.path("../secret",false);throw new AssertionError();}catch(IllegalArgumentException expected){}count++;
            System.out.println("SnapshotCaptureTest: "+count+" checks passed");
        }finally{remove(root);}
    }
}
