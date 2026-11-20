package local.hanvon.companion;
import java.util.*;
public final class ContentAccessPolicyTest {
 static void check(boolean condition) { if(!condition) throw new AssertionError(); }
 public static void main(String[] args) {
  String version="11111111-2222-4333-8444-555555555555",other="11111111-2222-4333-8444-555555555556";
  Set<String> grants=new HashSet<>(Arrays.asList("owner-A"));
  check(ContentAccessPolicy.allowed(version,version,"owner-A",true,grants));
  check(!ContentAccessPolicy.allowed(version,version,"owner-B",true,grants));
  check(!ContentAccessPolicy.allowed(version,other,"owner-A",true,grants));
  check(!ContentAccessPolicy.allowed(version,version,"owner-A",false,grants));
  check(!ContentAccessPolicy.allowed(version,version,null,true,grants));
  grants.clear();check(!ContentAccessPolicy.allowed(version,version,"owner-A",true,grants));
  check(ContentAccessPolicy.id(version).equals(version));
  for(String invalid:new String[]{"../source","", "1-1-1-1-1",version+"/x",version.toUpperCase().replace('5','Z')}) {
   try { ContentAccessPolicy.id(invalid);throw new AssertionError(); }catch(IllegalArgumentException expected){}
  }
  check(ContentAccessPolicy.live(1000,1000));check(ContentAccessPolicy.live(1000,600999));
  check(!ContentAccessPolicy.live(1000,601000));check(!ContentAccessPolicy.live(1000,999));
  System.out.println("ContentAccessPolicy: owner, revision, revocation, strict identifiers and expiry passed");
 }
}
