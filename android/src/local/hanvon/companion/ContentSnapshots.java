package local.hanvon.companion;

import android.content.Context;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;
import org.json.*;

/** Private immutable artifacts; never writes back to the selected SAF tree. */
final class ContentSnapshots implements AutoCloseable {
    static final class Problem extends Exception {
        final int status; final String code;
        Problem(int status,String code,String message){super(message);this.status=status;this.code=code;}
    }
    private static final Object LOCK=new Object();
    private static final Set<ContentSnapshots> INSTANCES=new HashSet<>();
    private static final long LEASE=86400000L, TOTAL=2L*1024*1024*1024;
    private final Context context; private final ContentSources sources; private final File root;
    private final Map<String,JSONObject> records=new HashMap<>();
    private final ScheduledExecutorService housekeeping=Executors.newSingleThreadScheduledExecutor();
    private final ExecutorService worker=Executors.newSingleThreadExecutor();
    private Future<?> preparing; private String active; private volatile boolean closed;
    ContentSnapshots(Context context,ContentSources sources) throws Exception {
        this.context=context.getApplicationContext();this.sources=sources;root=new File(context.getFilesDir(),"content-snapshots-v1");
        if(!root.isDirectory()&&!root.mkdirs())throw new IOException("Cannot create snapshots");
        synchronized(LOCK){
            File[] folders=root.listFiles();if(folders!=null)for(File folder:folders){
                try{
                    ContentAccessPolicy.id(folder.getName());File journal=new File(folder,"record.json");
                    if(!journal.isFile()||journal.length()>16*1024*1024)throw new IOException();
                    JSONObject r=new JSONObject(new String(Files.readAllBytes(journal.toPath()),StandardCharsets.UTF_8));
                    if(!folder.getName().equals(r.getString("id")))throw new IOException();
                    if("preparing".equals(r.getString("state"))){r.put("state","failed").put("code","PREPARATION_INTERRUPTED").put("message","服务在准备时停止，请创建新的导出任务");delete(new File(folder,"artifacts"));save(r);}
                    records.put(folder.getName(),r);
                }catch(Exception failure){delete(folder);}
            }
            INSTANCES.add(this);expireLocked();
        }
        pruneAccess();
        housekeeping.scheduleWithFixedDelay(()->{try{pruneAccess();synchronized(LOCK){expireLocked();}}catch(Exception ignored){}},1,1,TimeUnit.MINUTES);
    }
    private File folder(String id){return new File(root,id);}
    private void save(JSONObject r) throws Exception {
        File f=folder(r.getString("id"));if(!f.isDirectory()&&!f.mkdirs())throw new IOException("Cannot create snapshot journal");
        File tmp=new File(f,"record.tmp");try(FileOutputStream out=new FileOutputStream(tmp)){out.write(r.toString().getBytes(StandardCharsets.UTF_8));out.getFD().sync();}
        Files.move(tmp.toPath(),new File(f,"record.json").toPath(),StandardCopyOption.REPLACE_EXISTING,StandardCopyOption.ATOMIC_MOVE);
    }
    private static void delete(File file){File[] children=file.listFiles();if(children!=null)for(File f:children)delete(f);file.delete();}
    static void invalidate(Context context,String sourceID){synchronized(LOCK){for(ContentSnapshots store:INSTANCES)store.invalidateLocked(sourceID);}}
    private void invalidateLocked(String sourceID){
        for(JSONObject r:records.values())try{if(sourceID==null||sourceID.equals(r.getString("sourceID")))endLocked(r,"revoked");}catch(Exception ignored){}
    }
    private void endLocked(JSONObject r,String state) throws Exception {
        if(r.getString("id").equals(active)){if(preparing!=null)preparing.cancel(true);active=null;preparing=null;}
        delete(new File(folder(r.getString("id")),"artifacts"));
        r.put("state",state).put("entries",new JSONArray()).put("bytes",0).put("expires",System.currentTimeMillis()+LEASE);save(r);
    }
    private void expireLocked() throws Exception {
        long now=System.currentTimeMillis();Iterator<JSONObject> iterator=records.values().iterator();
        while(iterator.hasNext()){
            JSONObject r=iterator.next();String state=r.getString("state");long expiry=r.getLong("expires");
            if(expiry<now){
                if("ready".equals(state)||"preparing".equals(state)){endLocked(r,"expired");}
                else if(now-expiry>7*LEASE){delete(folder(r.getString("id")));iterator.remove();}
            }
        }
    }
    private void pruneAccess(){
        List<JSONObject> copy=new ArrayList<>();synchronized(LOCK){for(JSONObject r:records.values())if("ready".equals(r.optString("state"))||"preparing".equals(r.optString("state")))try{copy.add(new JSONObject(r.toString()));}catch(Exception ignored){}}
        for(JSONObject r:copy)try{sources.requireOwner(r.getString("owner"),r.getString("sourceID"),r.getString("revision"));}
        catch(Exception denied){synchronized(LOCK){JSONObject current=records.get(r.optString("id"));if(current!=null)try{endLocked(current,"revoked");}catch(Exception ignored){}}}
    }
    JSONObject create(String token,LanServer.Request request) throws Exception {
        String id=ContentAccessPolicy.id(request.param("requestID")),sourceID=ContentAccessPolicy.id(request.param("sourceID")),revision=ContentAccessPolicy.id(request.param("revision"));
        String selected=request.param("path"),index=request.param("index"),hash=request.param("indexSHA256"),dir=request.param("directory");
        SnapshotCapture.path(selected,true);SnapshotCapture.path(index,true);
        if(!"true".equals(dir)&&!"false".equals(dir))throw new IllegalArgumentException();
        if(!index.isEmpty()){ResumeFile.hash(hash);if(!index.endsWith(".database/HvNote.db"))throw new IllegalArgumentException();}else if(!hash.isEmpty())throw new IllegalArgumentException();
        sources.require(token,sourceID,revision);String owner=PairedMacs.digest(token);
        JSONObject r;
        synchronized(LOCK){
            expireLocked();if(closed)throw new Problem(429,"BUSY","服务正在停止");
            r=records.get(id);
            if(r!=null){
                if(!owner.equals(r.getString("owner")))throw new Problem(404,"SNAPSHOT_MISSING","未找到此快照");
                if(!sourceID.equals(r.getString("sourceID"))||!revision.equals(r.getString("revision"))||!selected.equals(r.getString("path"))||!index.equals(r.getString("index"))||!hash.equals(r.getString("indexSHA256"))||!dir.equals(r.getString("directory")))throw new Problem(409,"REQUEST_CONFLICT","快照请求编号已被其他参数使用");
                requireLive(r);return summary(r);
            }
            if(active!=null)throw new Problem(429,"BUSY","电纸书正在准备另一份内容，请稍后重试");
            long used=0;for(JSONObject old:records.values())if("ready".equals(old.getString("state")))used+=old.optLong("bytes");
            int live=0;for(JSONObject old:records.values())if("ready".equals(old.optString("state"))||"preparing".equals(old.optString("state")))live++;
            if(live>=128||records.size()>=10000||used>=TOTAL)throw new Problem(507,"SNAPSHOT_QUOTA","快照缓存达到限额，请释放旧任务或等待过期");
            r=new JSONObject().put("id",id).put("owner",owner).put("sourceID",sourceID).put("revision",revision).put("path",selected).put("directory",dir).put("index",index).put("indexSHA256",hash)
                .put("state","preparing").put("expires",System.currentTimeMillis()+LEASE).put("bytes",0).put("files",0).put("entries",new JSONArray());
            save(r);records.put(id,r);active=id;final JSONObject record=r;final long budget=Math.min(SnapshotCapture.MAX_BYTES,TOTAL-used);
            preparing=worker.submit(()->prepare(token,record,budget));return summary(r);
        }
    }
    private void prepare(String token,JSONObject record,long budget){
        JSONObject config; synchronized(LOCK){try{config=new JSONObject(record.toString());}catch(Exception invalid){return;}}
        String id=config.optString("id"),source=config.optString("sourceID"),revision=config.optString("revision");File artifacts=new File(folder(id),"artifacts");
        try{
            if(!artifacts.mkdirs())throw new IOException("Cannot create artifacts");
            final SharedTree tree=sources.require(token,source,revision);
            SnapshotCapture.Source input=new SnapshotCapture.Source(){
                public void check() throws Exception {if(closed||Thread.currentThread().isInterrupted())throw new InterruptedIOException();sources.require(token,source,revision);}
                public List<SnapshotCapture.Entry> list(String path) throws Exception {
                    List<SnapshotCapture.Entry> rows=new ArrayList<>();for(SharedTree.Entry e:tree.snapshotEntries(path))rows.add(new SnapshotCapture.Entry(path.isEmpty()?e.name:path+"/"+e.name,e.directory,e.size,e.modified));return rows;
                }
                public InputStream open(String path) throws Exception {check();return context.getContentResolver().openInputStream(tree.file(path).uri);}
            };
            List<SnapshotCapture.Entry> captured=SnapshotCapture.capture(input,config.getString("path"),Boolean.parseBoolean(config.getString("directory")),config.getString("index"),config.getString("indexSHA256"),artifacts,budget,SnapshotCapture.RESERVE,(bytes,files)->{
                synchronized(LOCK){if(!"preparing".equals(record.optString("state")))throw new InterruptedIOException();record.put("bytes",bytes).put("files",files);}
            });
            JSONArray entries=new JSONArray();for(SnapshotCapture.Entry e:captured)entries.put(new JSONObject().put("path",e.path).put("directory",e.directory).put("size",e.size==null?JSONObject.NULL:e.size).put("modified",e.modified==null?JSONObject.NULL:e.modified).put("artifact",e.artifact==null?JSONObject.NULL:e.artifact).put("sha256",e.sha256==null?JSONObject.NULL:e.sha256));
            if(entries.toString().getBytes(StandardCharsets.UTF_8).length>8*1024*1024)throw new SnapshotCapture.Failure("SCOPE_LIMIT","资源清单过大，请缩小范围");
            String manifestHash=ResumeFile.digest(new ByteArrayInputStream(entries.toString().getBytes(StandardCharsets.UTF_8)));
            input.check();synchronized(LOCK){if(!"preparing".equals(record.optString("state")))throw new InterruptedIOException();record.put("entries",entries).put("manifestSHA256",manifestHash).put("state","ready").put("expires",System.currentTimeMillis()+LEASE);save(record);}
        }catch(Exception failure){synchronized(LOCK){try{
            if("preparing".equals(record.optString("state"))){String code=failure instanceof SnapshotCapture.Failure?((SnapshotCapture.Failure)failure).code:failure instanceof LanServer.Problem&&((LanServer.Problem)failure).status==403?"SOURCE_REVOKED":"PREPARATION_FAILED";
                endLocked(record,"failed");record.put("code",code).put("message",failure instanceof SnapshotCapture.Failure?failure.getMessage():"快照准备未完成，请检查来源权限、设备空间并重新创建任务");save(record);}
        }catch(Exception ignored){}}delete(artifacts);
        }finally{synchronized(LOCK){if(id.equals(active)){active=null;preparing=null;}}}
    }
    private JSONObject authorized(String token,String id) throws Exception {
        ContentAccessPolicy.id(id);JSONObject r;String sourceID,revision;
        synchronized(LOCK){expireLocked();r=records.get(id);if(r==null||!PairedMacs.digest(token).equals(r.getString("owner")))throw new Problem(410,"SNAPSHOT_EXPIRED","快照已不存在或过期，请创建新的导出任务");sourceID=r.getString("sourceID");revision=r.getString("revision");}
        sources.require(token,sourceID,revision);
        return r;
    }
    private void requireLive(JSONObject r) throws Exception {
        String state=r.getString("state");if(!"preparing".equals(state)&&!"ready".equals(state)&&!"failed".equals(state))throw new Problem(410,"SNAPSHOT_EXPIRED","快照已释放或过期，请创建新的导出任务");
    }
    private JSONObject summary(JSONObject r) throws Exception {
        return new JSONObject().put("id",r.getString("id")).put("sourceID",r.getString("sourceID")).put("revision",r.getString("revision")).put("state",r.getString("state"))
            .put("bytes",r.optLong("bytes")).put("files",r.optInt("files")).put("remainingSeconds",Math.max(0,(r.getLong("expires")-System.currentTimeMillis())/1000))
            .put("manifestSHA256",r.optString("manifestSHA256","")).put("code",r.optString("code","")).put("message",r.optString("message",""))
            .put("maxBytes",SnapshotCapture.MAX_BYTES).put("totalMaxBytes",TOTAL).put("maxChunkBytes",ResumeFile.CHUNK);
    }
    JSONObject status(String token,String id,int offset) throws Exception {
        JSONObject r=authorized(token,id);synchronized(LOCK){requireLive(r);r.put("expires",System.currentTimeMillis()+LEASE);save(r);JSONObject reply=summary(r);JSONArray all=r.getJSONArray("entries"),page=new JSONArray();if(offset<0||offset>all.length())throw new IllegalArgumentException();
            int pageBytes=0;for(int i=offset;i<Math.min(all.length(),offset+200);i++){Object entry=all.get(i);int n=entry.toString().getBytes(StandardCharsets.UTF_8).length;if(pageBytes+n>1500000)break;page.put(entry);pageBytes+=n;}return reply.put("entries",page).put("offset",offset).put("totalEntries",all.length());}
    }
    JSONObject artifact(String token,String id,String artifact) throws Exception {
        ContentAccessPolicy.id(artifact);JSONObject r=authorized(token,id);synchronized(LOCK){requireLive(r);if(!"ready".equals(r.getString("state")))throw new Problem(409,"NOT_READY","快照尚未就绪");JSONArray entries=r.getJSONArray("entries");
            for(int i=0;i<entries.length();i++){JSONObject e=entries.getJSONObject(i);if(artifact.equals(e.optString("artifact"))){r.put("expires",System.currentTimeMillis()+LEASE);return new JSONObject(e.toString());}}
            throw new Problem(404,"ARTIFACT_MISSING","快照中没有此资源");}
    }
    byte[] chunk(String token,String id,String artifact,long offset,long count) throws Exception {
        JSONObject e=artifact(token,id,artifact);long size=e.getLong("size");if(count>ResumeFile.CHUNK||offset>size||count>size-offset)throw new IllegalArgumentException();byte[] bytes=new byte[(int)count];
        synchronized(LOCK){try(RandomAccessFile input=new RandomAccessFile(new File(new File(folder(id),"artifacts"),artifact),"r")){if(input.length()!=size)throw new Problem(410,"SNAPSHOT_EXPIRED","快照资源已失效");input.seek(offset);input.readFully(bytes);}}
        authorized(token,id);return bytes;
    }
    JSONObject release(String token,String id) throws Exception {JSONObject r=authorized(token,id);synchronized(LOCK){endLocked(r,"released");}return new JSONObject().put("ok",true);}
    public void close(){closed=true;worker.shutdownNow();housekeeping.shutdownNow();synchronized(LOCK){INSTANCES.remove(this);}}
}
