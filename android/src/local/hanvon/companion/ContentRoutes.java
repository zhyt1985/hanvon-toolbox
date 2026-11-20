package local.hanvon.companion;

import android.content.Context;
import java.io.OutputStream;
import org.json.JSONArray;
import org.json.JSONObject;

final class ContentRoutes {
    private final ContentSources sources;
    private final Runnable changed;
    private final ContentSnapshots snapshots;
    ContentRoutes(Context context,Runnable changed) throws Exception { sources=new ContentSources(context);this.changed=changed;snapshots=new ContentSnapshots(context,sources); }
    void close(){snapshots.close();}

    void handle(LanServer.Request request,OutputStream output) throws Exception {
        try { dispatch(request,output); }
        catch(ContentSnapshots.Problem failure) { LanServer.json(output,failure.status,new JSONObject().put("error",new JSONObject().put("code",failure.code).put("message",failure.getMessage()).put("retryable",failure.status==429))); }
        catch(IllegalArgumentException failure) { throw new LanServer.Problem(400,"内容来源参数无效"); }
    }
    private void dispatch(LanServer.Request request,OutputStream output) throws Exception {
        String route=request.method+" "+request.route;
        if(request.length>0) throw new LanServer.Problem(400,"内容只读接口不接受文件上传");
        String token=request.headers.get("x-hanvon-token");
        if(request.route.startsWith("/v1/content/snapshots")) {
            if("POST /v1/content/snapshots".equals(route)){LanServer.json(output,202,snapshots.create(token,request));return;}
            String id=request.param("snapshotID");
            if("GET /v1/content/snapshots/status".equals(route)||"POST /v1/content/snapshots/lease".equals(route)) {
                long offset=ResumeFile.count(request.param("offset"));if(offset>20000)throw new IllegalArgumentException();
                LanServer.json(output,200,snapshots.status(token,id,(int)offset));return;
            }
            if("POST /v1/content/snapshots/release".equals(route)){LanServer.json(output,200,snapshots.release(token,id));return;}
            String artifact=request.param("artifactID");
            if("GET /v1/content/snapshots/artifact/info".equals(route)){LanServer.json(output,200,snapshots.artifact(token,id,artifact));return;}
            if("GET /v1/content/snapshots/artifact/chunk".equals(route)) {
                byte[] bytes=snapshots.chunk(token,id,artifact,ResumeFile.count(request.param("offset")),ResumeFile.count(request.param("count")));
                LanServer.header(output,200,"application/octet-stream",(long)bytes.length);output.write(bytes);output.flush();return;
            }
            throw new LanServer.Problem(404,"快照操作不可用");
        }
        if("GET /v1/content/sources".equals(route)) {
            LanServer.json(output,200,sources.remoteSources(token));return;
        }
        if("POST /v1/content/access-requests".equals(route)) {
            JSONObject result=sources.request(token,request.param("sourceID"));
            LanServer.json(output,200,result);changed.run();return;
        }
        if("GET /v1/content/access-request".equals(route)) {
            LanServer.json(output,200,sources.status(token,request.param("id")));return;
        }
        // Reject unsupported operations before resolving any source.
        if(!"GET /v1/content/list".equals(route)
            && !"GET /v1/content/resume/download/info".equals(route)
            && !"GET /v1/content/resume/download/chunk".equals(route)
            && !"POST /v1/content/resume/abort".equals(route)) throw new LanServer.Problem(404,"此内容操作不可用");
        String id=request.param("sourceID"),revision=request.param("revision");
        SharedTree tree=sources.require(token,id,revision);
        if("GET /v1/content/list".equals(route)) {
            JSONArray result=tree.list(request.param("path"));
            if(result.length()>20000 || result.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8).length>2*1024*1024)
                throw new LanServer.Problem(413,"来源目录过大，请选择更小的来源");
            sources.require(token,id,revision);
            LanServer.json(output,200,result);return;
        }
        ResumeStore resume=sources.resume(token,id,revision,tree);
        if("GET /v1/content/resume/download/info".equals(route)) {
            JSONObject result=resume.downloadInfo(request);
            sources.require(token,id,revision);
            LanServer.json(output,200,result);
        } else if("GET /v1/content/resume/download/chunk".equals(route)) {
            byte[] bytes=resume.downloadChunk(request);
            sources.require(token,id,revision);
            LanServer.header(output,200,"application/octet-stream",(long)bytes.length);
            output.write(bytes);output.flush();
        } else {
            resume.abort(request);LanServer.json(output,200,new JSONObject().put("ok",true));
        }
    }
}
