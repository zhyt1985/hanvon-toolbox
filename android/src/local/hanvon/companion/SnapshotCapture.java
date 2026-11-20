package local.hanvon.companion;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.text.Normalizer;
import java.util.*;

/** Streaming, bounded capture. Stable observations are not a database transaction. */
final class SnapshotCapture {
    static final long MAX_BYTES=1024L*1024*1024, RESERVE=256L*1024*1024;
    static final int MAX_ENTRIES=20000;
    static final class Failure extends IOException {
        final String code;
        Failure(String code,String message){super(message);this.code=code;}
    }
    static final class Entry {
        final String path; final boolean directory; final Long size,modified;
        String artifact,sha256;
        Entry(String path,boolean directory,Long size,Long modified){this.path=path;this.directory=directory;this.size=size;this.modified=modified;}
        boolean same(Entry b){return path.equals(b.path)&&directory==b.directory&&Objects.equals(size,b.size)&&Objects.equals(modified,b.modified);}
    }
    interface Source {
        List<Entry> list(String path) throws Exception;
        InputStream open(String path) throws Exception;
        void check() throws Exception;
    }
    interface Progress { void update(long bytes,int files) throws Exception; }
    static void path(String path,boolean root) {
        if(root&&path.isEmpty())return;
        String[] parts=path.split("/",-1);
        if(parts.length>64)throw new IllegalArgumentException("Path depth");
        for(String p:parts) {
            if(p.isEmpty()||p.equals(".")||p.equals("..")||p.getBytes(StandardCharsets.UTF_8).length>255)throw new IllegalArgumentException("Path component");
            for(char c:p.toCharArray())if(c=='\\'||c==':'||Character.isISOControl(c))throw new IllegalArgumentException("Path component");
        }
    }
    static String parent(String p){int i=p.lastIndexOf('/');return i<0?"":p.substring(0,i);}
    private static String key(String p){return Normalizer.normalize(p,Normalizer.Form.NFC).toLowerCase(Locale.ROOT);}
    private static final class Inventory extends TreeMap<String,Entry> { int pathBytes; }
    private static void add(Map<String,Entry> entries,Set<String> names,Entry e) throws Exception {
        path(e.path,false);
        if(entries.containsKey(e.path))return;
        if(entries.size()>=MAX_ENTRIES||!names.add(key(e.path)))throw new Failure("SCOPE_LIMIT","来源数量过多或存在重名，请缩小范围");
        if(entries instanceof Inventory){Inventory inventory=(Inventory)entries;inventory.pathBytes+=e.path.getBytes(StandardCharsets.UTF_8).length;if(inventory.pathBytes>4*1024*1024)throw new Failure("SCOPE_LIMIT","资源清单路径过多，请缩小范围");}
        entries.put(e.path,e);
    }
    private static List<Entry> children(Source source,String path) throws Exception {
        source.check();List<Entry> entries=source.list(path);Set<String> names=new HashSet<>();
        if(entries.size()>MAX_ENTRIES)throw new Failure("SCOPE_LIMIT","来源目录过大");
        for(Entry e:entries){SnapshotCapture.path(e.path,false);if(!parent(e.path).equals(path)||!names.add(key(e.path)))throw new Failure("SCOPE_LIMIT","来源目录存在无效名称或重名");
            if((e.path.endsWith("-wal")||e.path.endsWith("-journal"))&&!Objects.equals(e.size,0L))throw new Failure("UNSTABLE_DATABASE","来源数据库有活动事务，请保存后重新准备");}
        return entries;
    }
    private static void walk(Source source,String p,Map<String,Entry> entries,Set<String> names) throws Exception {
        for(Entry e:children(source,p)){add(entries,names,e);if(e.directory)walk(source,e.path,entries,names);}
    }
    private static void select(Source source,String path,boolean directory,Map<String,Entry> entries,Set<String> names) throws Exception {
        if(path.isEmpty()){if(!directory)throw new IllegalArgumentException();walk(source,path,entries,names);return;}
        Entry found=null;for(Entry e:children(source,parent(path)))if(e.path.equals(path))found=e;
        if(found==null||found.directory!=directory)throw new Failure("SOURCE_CHANGED","来源已改名、移动或改变类型");
        add(entries,names,found);if(directory)walk(source,path,entries,names);
    }
    private static Map<String,Entry> inventory(Source source,String selected,boolean directory,String index) throws Exception {
        Map<String,Entry> entries=new Inventory();Set<String> names=new HashSet<>();select(source,selected,directory,entries,names);
        if(!index.isEmpty())select(source,index,false,entries,names);
        // Virtual ancestors are required for scope-relative lookup, not additional resource reads.
        for(String p:new ArrayList<>(entries.keySet()))while(!(p=parent(p)).isEmpty())add(entries,names,new Entry(p,true,null,null));
        return entries;
    }
    static List<Entry> capture(Source source,String selected,boolean directory,String index,String expectedIndex,
                               File output,long limit,long reserve,Progress progress) throws Exception {
        path(selected,true);if(!index.isEmpty())path(index,false);
        Map<String,Entry> before=inventory(source,selected,directory,index);
        long total=0;for(Entry e:before.values())if(!e.directory){if(e.size==null||e.size<0||e.size>limit-total)throw new Failure("SNAPSHOT_QUOTA","来源大小未知或超过快照限额，请分批导出");total+=e.size;}
        if(output.getUsableSpace()<reserve+total)throw new Failure("SNAPSHOT_QUOTA","设备快照空间不足，请释放空间或改用 USB");
        long copied=0;int files=0;byte[] buffer=new byte[65536];
        for(Entry e:before.values())if(!e.directory){
            source.check();e.artifact=UUID.randomUUID().toString();MessageDigest hash=MessageDigest.getInstance("SHA-256");long count=0;
            try(InputStream in=source.open(e.path);FileOutputStream out=new FileOutputStream(new File(output,e.artifact))){
                if(in==null)throw new EOFException();int n;
                while((n=in.read(buffer))!=-1){source.check();if(Thread.currentThread().isInterrupted())throw new InterruptedIOException();if(n>e.size-count)throw new Failure("SOURCE_CHANGED","来源文件在准备期间变大");
                    if(output.getUsableSpace()<reserve+n)throw new Failure("SNAPSHOT_QUOTA","设备快照空间不足");out.write(buffer,0,n);hash.update(buffer,0,n);count+=n;copied+=n;progress.update(copied,files);}
                out.getFD().sync();
            }
            if(count!=e.size)throw new Failure("SOURCE_CHANGED","来源文件在准备期间改变");
            e.sha256=hex(hash.digest());if(e.path.equals(index)&&!e.sha256.equals(expectedIndex))throw new Failure("SOURCE_CHANGED","笔记索引已变化，请重新扫描");
            files++;progress.update(copied,files);
        }
        // A second full read detects changes that preserve file size and modification time.
        for(Entry e:before.values())if(!e.directory){
            MessageDigest hash=MessageDigest.getInstance("SHA-256");long count=0;
            try(InputStream in=source.open(e.path)){if(in==null)throw new EOFException();int n;while((n=in.read(buffer))!=-1){source.check();if(Thread.currentThread().isInterrupted())throw new InterruptedIOException();count+=n;if(count>e.size)throw new Failure("SOURCE_CHANGED","来源文件已改变");hash.update(buffer,0,n);}}
            if(count!=e.size||!e.sha256.equals(hex(hash.digest())))throw new Failure("SOURCE_CHANGED","来源仍在变化，请保存后重新准备");
        }
        Map<String,Entry> after=inventory(source,selected,directory,index);
        if(!before.keySet().equals(after.keySet()))throw new Failure("SOURCE_CHANGED","来源目录成员已改变");
        for(String p:before.keySet())if(!before.get(p).same(after.get(p)))throw new Failure("SOURCE_CHANGED","来源大小、类型或时间已改变");
        source.check();return new ArrayList<>(before.values());
    }
    static String hex(byte[] bytes){StringBuilder b=new StringBuilder();for(byte v:bytes)b.append(String.format(Locale.ROOT,"%02x",v&255));return b.toString();}
}
