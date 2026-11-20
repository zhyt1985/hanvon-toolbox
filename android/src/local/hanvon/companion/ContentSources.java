package local.hanvon.companion;

import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.Uri;
import android.content.UriPermission;
import java.io.File;
import java.util.*;
import java.security.SecureRandom;
import org.json.JSONArray;
import org.json.JSONObject;

/** All source mutation is local UI only. Remote methods never accept arbitrary URIs. */
final class ContentSources {
    private static final Object LOCK = new Object();
    private final Context context;
    private final SharedPreferences prefs;
    private final PairedMacs paired;
    ContentSources(Context context) {
        this.context = context.getApplicationContext();
        prefs = context.getSharedPreferences("content-sources-v1", Context.MODE_PRIVATE);
        paired = new PairedMacs(context);
    }
    private JSONArray sources() throws Exception { return new JSONArray(prefs.getString("sources", "[]")); }
    private JSONArray requests() throws Exception { return new JSONArray(prefs.getString("requests", "[]")); }
    private void save(String key, JSONArray value) throws Exception {
        if (!prefs.edit().putString(key, value.toString()).commit()) throw new java.io.IOException("Cannot save content access");
    }
    private JSONObject find(JSONArray array, String id) throws Exception {
        for (int i=0;i<array.length();i++) if (id.equals(array.getJSONObject(i).getString("id"))) return array.getJSONObject(i);
        throw new LanServer.Problem(404, "内容来源或请求已不存在");
    }
    private Set<String> grants(JSONObject source) throws Exception {
        Set<String> result = new HashSet<>();
        JSONArray a=source.getJSONArray("grants");
        for(int i=0;i<a.length();i++) result.add(a.getString(i));
        return result;
    }
    private boolean persisted(Uri uri) {
        for(UriPermission p:context.getContentResolver().getPersistedUriPermissions()) {
            if(p.isReadPermission() && p.getUri().equals(uri)) return true;
        }
        return false;
    }
    JSONArray localSources() throws Exception { synchronized(LOCK) { return sources(); } }
    boolean uses(Uri uri) {
        synchronized(LOCK) {
            try { JSONArray a=sources();for(int i=0;i<a.length();i++) if(uri.toString().equals(a.getJSONObject(i).getString("uri"))) return true; }
            catch(Exception ignored) {}
            return false;
        }
    }
    void add(Uri uri, String kind) throws Exception {
        if (!"notes".equals(kind) && !"files".equals(kind)) throw new IllegalArgumentException();
        synchronized(LOCK) {
            if(!persisted(uri)) throw new LanServer.Problem(403,"请授予持久只读访问");
            JSONArray a=sources();
            String name=new SharedTree(context,uri).name();
            for(int i=0;i<a.length();i++) {
                JSONObject old=a.getJSONObject(i);
                if(uri.toString().equals(old.getString("uri")) && kind.equals(old.getString("kind"))) {
                    clearCache(old.getString("id"));
                    old.put("revision",UUID.randomUUID().toString()).put("name",name).put("grants",new JSONArray());
                    save("sources",a);return;
                }
            }
            if(a.length()>=8) throw new LanServer.Problem(409,"最多设置 8 个内容来源，请先移除不用的来源");
            a.put(new JSONObject().put("id",UUID.randomUUID().toString()).put("revision",UUID.randomUUID().toString())
                .put("name",name).put("kind",kind).put("uri",uri.toString()).put("grants",new JSONArray()));
            save("sources",a);
        }
    }
    void remove(String id) throws Exception {
        synchronized(LOCK) {
            JSONArray a=sources(),next=new JSONArray();
            JSONObject old=find(a,id);
            for(int i=0;i<a.length();i++) if(!id.equals(a.getJSONObject(i).getString("id"))) next.put(a.getJSONObject(i));
            save("sources",next);clearCache(id);
            Uri uri=Uri.parse(old.getString("uri"));
            String management=WirelessService.preferences(context).getString("tree",null);
            if(!uri.toString().equals(management) && !uses(uri)) {
                try {context.getContentResolver().releasePersistableUriPermission(uri,Intent.FLAG_GRANT_READ_URI_PERMISSION);}
                catch(SecurityException ignored) {}
            }
        }
    }
    void revoke(String id) throws Exception {
        synchronized(LOCK) {
            JSONArray a=sources();JSONObject s=find(a,id);
            s.put("revision",UUID.randomUUID().toString()).put("grants",new JSONArray());
            save("sources",a);clearCache(id);
        }
    }
    void clearMacs() {
        synchronized(LOCK) {
            try {
                JSONArray a=sources();
                for(int i=0;i<a.length();i++) a.getJSONObject(i).put("revision",UUID.randomUUID().toString()).put("grants",new JSONArray());
                save("sources",a);save("requests",new JSONArray());
                delete(new File(context.getFilesDir(),"content-resume"));ContentSnapshots.invalidate(context,null);
            } catch(Exception failure) { throw new IllegalStateException(failure); }
        }
    }
    JSONArray remoteSources(String token) throws Exception {
        synchronized(LOCK) {
            String owner=PairedMacs.digest(token);
            JSONArray output=new JSONArray(),a=sources();
            for(int i=0;i<a.length();i++) {
                JSONObject s=a.getJSONObject(i);
                boolean approved=ContentAccessPolicy.allowed(s.getString("revision"),s.getString("revision"),owner,paired.contains(token),grants(s));
                boolean readable=persisted(Uri.parse(s.getString("uri")));
                output.put(new JSONObject().put("id",s.getString("id")).put("revision",s.getString("revision"))
                    .put("kind",s.getString("kind")).put("name",approved?s.getString("name"):"未授权内容来源 "+(i+1))
                    .put("authorized",approved&&readable).put("readable",readable));
            }
            return output;
        }
    }
    private JSONArray pruned() throws Exception {
        JSONArray output=new JSONArray(),a=requests();
        for(int i=0;i<a.length();i++) {
            JSONObject r=a.getJSONObject(i);
            if(ContentAccessPolicy.live(r.getLong("created"),System.currentTimeMillis()) && paired.knowsDigest(r.getString("owner"))) {
                try {
                    JSONObject source=find(sources(),r.getString("sourceID"));
                    if(source.getString("revision").equals(r.getString("revision"))) output.put(r);
                } catch(LanServer.Problem ignored) {}
            }
        }
        return output;
    }
    JSONObject request(String token,String sourceID) throws Exception {
        synchronized(LOCK) {
            ContentAccessPolicy.id(sourceID);
            JSONObject source=find(sources(),sourceID);
            if(!paired.contains(token)) throw new LanServer.Problem(401,"配对已失效");
            String owner=PairedMacs.digest(token);
            JSONArray a=pruned();
            for(int i=0;i<a.length();i++) {
                JSONObject r=a.getJSONObject(i);
                if(owner.equals(r.getString("owner")) && sourceID.equals(r.getString("sourceID"))
                    && source.getString("revision").equals(r.getString("revision")) && "pending".equals(r.getString("state"))) return publicRequest(r);
            }
            if(a.length()>=16) throw new LanServer.Problem(429,"授权请求过多，请在设备上处理后重试");
            JSONObject r=new JSONObject().put("id",UUID.randomUUID().toString()).put("sourceID",sourceID)
                .put("revision",source.getString("revision")).put("owner",owner).put("created",System.currentTimeMillis())
                .put("code",String.format(java.util.Locale.ROOT,"%06d",new SecureRandom().nextInt(1000000))).put("state","pending");
            a.put(r);save("requests",a);return publicRequest(r);
        }
    }
    JSONObject status(String token,String requestID) throws Exception {
        synchronized(LOCK) {
            ContentAccessPolicy.id(requestID);
            JSONObject r=find(pruned(),requestID);
            if(!r.getString("owner").equals(PairedMacs.digest(token))) throw new LanServer.Problem(403,"不能读取其他 Mac 的授权请求");
            JSONObject s=find(sources(),r.getString("sourceID"));
            if(!s.getString("revision").equals(r.getString("revision"))) throw new LanServer.Problem(409,"来源授权已变化，请重新申请");
            return publicRequest(r);
        }
    }
    JSONArray pending() throws Exception {
        synchronized(LOCK) {
            JSONArray output=new JSONArray(),a=pruned();
            for(int i=0;i<a.length();i++) {
                JSONObject r=a.getJSONObject(i);
                if(!"pending".equals(r.getString("state"))) continue;
                try {
                    JSONObject s=find(sources(),r.getString("sourceID"));
                    if(s.getString("revision").equals(r.getString("revision"))) {
                        output.put(new JSONObject(r.toString()).put("sourceName",s.getString("name")));
                    }
                } catch(LanServer.Problem ignored) {}
            }
            return output;
        }
    }
    void decide(String requestID,boolean allow) throws Exception {
        synchronized(LOCK) {
            JSONArray a=pruned(),ss=sources();JSONObject r=find(a,requestID),s=find(ss,r.getString("sourceID"));
            if(!"pending".equals(r.getString("state")) || !s.getString("revision").equals(r.getString("revision"))) throw new LanServer.Problem(409,"请求已变化");
            if(!paired.knowsDigest(r.getString("owner"))) throw new LanServer.Problem(401,"此 Mac 已解除配对");
            if(allow) {
                if(!persisted(Uri.parse(s.getString("uri")))) throw new LanServer.Problem(403,"来源目录权限已失效");
                Set<String> owners=grants(s);owners.add(r.getString("owner"));
                s.put("grants",new JSONArray(owners));
            }
            r.put("state",allow?"approved":"denied");
            if(!prefs.edit().putString("sources",ss.toString()).putString("requests",a.toString()).commit()) {
                throw new java.io.IOException("Cannot save content decision");
            }
        }
    }
    private JSONObject publicRequest(JSONObject r) throws Exception {
        return new JSONObject().put("id",r.getString("id")).put("sourceID",r.getString("sourceID"))
            .put("code",r.getString("code")).put("state",r.getString("state"));
    }
    SharedTree require(String token,String id,String revision) throws Exception {
        synchronized(LOCK) {
            ContentAccessPolicy.id(id);ContentAccessPolicy.id(revision);
            JSONObject s=find(sources(),id);
            if(!ContentAccessPolicy.allowed(s.getString("revision"),revision,PairedMacs.digest(token),paired.contains(token),grants(s)))
                throw new LanServer.Problem(403,"内容来源未授权或授权已变化，请在电纸书确认");
            Uri uri=Uri.parse(s.getString("uri"));
            if(!persisted(uri)) throw new LanServer.Problem(403,"内容来源的系统权限已撤销");
            return new SharedTree(context,uri);
        }
    }
    SharedTree requireOwner(String owner,String id,String revision) throws Exception {
        synchronized(LOCK) {
            ContentAccessPolicy.id(id);ContentAccessPolicy.id(revision);
            JSONObject s=find(sources(),id);
            if(!paired.knowsDigest(owner)||!revision.equals(s.getString("revision"))||!grants(s).contains(owner))throw new LanServer.Problem(403,"内容来源授权已撤销");
            Uri uri=Uri.parse(s.getString("uri"));if(!persisted(uri))throw new LanServer.Problem(403,"内容来源系统权限已撤销");
            return new SharedTree(context,uri);
        }
    }
    ResumeStore resume(String token,String id,String revision,SharedTree tree) throws Exception {
        File folder=new File(new File(new File(new File(context.getFilesDir(),"content-resume"),id),revision),PairedMacs.digest(token));
        return new ResumeStore(context,tree,"content/"+id+"/"+revision+"/",folder);
    }
    private void clearCache(String id) { ContentSnapshots.invalidate(context,id);delete(new File(new File(context.getFilesDir(),"content-resume"),id)); }
    private static void delete(File file) {
        File[] children=file.listFiles();
        if(children!=null) for(File child:children) delete(child);
        file.delete();
    }
}
