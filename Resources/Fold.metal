// Crease curvature and perspective adapted from Bendable (MIT), commit 13848be.
// See ThirdParty/Bendable/LICENSE. Lower-panel blur isolation is specific to Duo Fold.
#include <metal_stdlib>
using namespace metal;
struct Params { float progress; float mode; float softness; float shadow; float perspective; float aspect; float sourceAspect; float padding; };
struct Varying { float4 position [[position]]; float2 uv; float3 world; };
// Keep the current desktop behind the moving panel, rather than exposing a black clear color.
vertex Varying desktopVertex(uint id [[vertex_id]],const device float2 *grid [[buffer(0)]],constant Params &p [[buffer(1)]]) {
 float2 uv=grid[id];float2 xy=float2(uv.x*2-1,1-uv.y*2);
 float2 fit=float2(min(1.0,p.sourceAspect/p.aspect),min(1.0,p.aspect/p.sourceAspect));
 Varying o;o.position=float4(xy*fit,.98,1);o.uv=uv;o.world=float3(xy,0);return o;
}
vertex Varying foldVertex(uint id [[vertex_id]],const device float2 *grid [[buffer(0)]],constant Params &p [[buffer(1)]]) {
 float2 uv=grid[id];float x=uv.x*2-1,y=1-uv.y*2,z=0;float f=p.progress;
 if(p.mode<0.5){if(y>0){float a=p.padding>=0 ? p.padding : p.progress*3.14159265;y=y*cos(a);float above=1-uv.y*2;float bend=smoothstep(0.0,.30,above)*(1-smoothstep(.30,1.6,above));z=sin(a)*above+.07*sin(a)*sin(a)*bend+.001*smoothstep(0.0,.05,a);}}
 else if(p.mode<1.5){float k=max(.0001,f*2.8);float t=y+1;y=-1+sin(t*k)/k;z=(1-cos(t*k))/k;}
 else if(p.mode<2.5){float t=(y+1)*3;float n=floor(t);float local=t-n;float a=f*1.54;y=-1+(n+local)*cos(a)*2/3;z=((int(n)%2==0)?local:1-local)*sin(a)*2/3;}
 else if(p.mode<3.5){z=f*.8*(1-x*x)*cos(y*1.1);y*=cos(f*1.15);x*=1-f*.15*y*y;}
 else {
  float2 q=float2(x,y);float radius=length(q);
  float theta=atan2(y,x);float hinge=.30;
  float t=max(0.0,radius-hinge);
  float a=f*(2.8+.32*sin(theta*4+1.0))*smoothstep(hinge,1.25,radius);
  float r=hinge+t*cos(a);
  if(radius>hinge){float2 bent=q/radius*r;x=bent.x;y=bent.y;z=t*sin(a);}
 }

 float2 fit=float2(min(1.0,p.sourceAspect/p.aspect),min(1.0,p.aspect/p.sourceAspect));
 float distance=mix(40.0,5.0,clamp(p.perspective,0.0,1.0));
 float w=max(.001,(distance+z)/distance);
 Varying o;o.position=float4(x*fit.x,y*fit.y,(.5-z*.15)*w,w);o.uv=uv;o.world=float3(x,y,z);return o;
}
fragment float4 foldFragment(Varying in [[stage_in]],bool front [[front_facing]],texture2d<float> sharp [[texture(0)]],texture2d<float> blurred [[texture(1)]],texture2d<float> lightBlur [[texture(2)]],constant Params &p [[buffer(1)]]) {
 constexpr sampler s(filter::linear,address::clamp_to_edge);
 if(p.mode>5.5) {
  float progress=smoothstep(0.0,1.0,clamp(p.progress,0.0,1.0));
  float coordinate=p.padding<.5 ? in.uv.x : (p.padding<1.5 ? in.uv.y : (p.padding<2.5 ? 1-in.uv.x : 1-in.uv.y));
  float along=(p.padding<.5 || (p.padding>1.5 && p.padding<2.5)) ? in.uv.y : in.uv.x;
  // Broad, softly undulating material front. No luminous edge or scanning line.
  float wave=(.045*sin(along*6.283+progress*2.1)+.022*sin(along*11.0-progress*1.7))*sin(progress*3.14159265);
  float front=mix(-.24,1.24,progress)+wave;
  float amount=1-smoothstep(front-.24,front+.24,coordinate);
  float rim=exp(-pow((coordinate-front)/.16,2.0))*sin(progress*3.14159265);
  float2 normal=p.padding<.5 ? float2(1,0) : (p.padding<1.5 ? float2(0,1) : (p.padding<2.5 ? float2(-1,0) : float2(0,-1)));
  float2 glassUV=in.uv+normal*(.009*rim*amount);
  float3 original=sharp.sample(s,in.uv).rgb;
  float3 soft=mix(lightBlur.sample(s,glassUV).rgb,blurred.sample(s,glassUV).rgb,smoothstep(.05,.95,amount)*.95);
  return float4(mix(original,soft,amount),1);
 }
 // Desktop Duo is a lid-driven frosted cover: retain the original page coordinates.
 if(p.mode<.5) {
  // The cover advances with the lid instead of occupying a fixed half-screen rectangle.
  float closure=clamp(p.progress,0.0,1.0);
  float edge=.92*sin(closure*1.57079633);
  float feather=mix(.025,.075,closure);
  float cover=1-smoothstep(edge-feather,edge,in.uv.y);
  float haze=clamp(p.softness*1.5,0.0,1.0)*smoothstep(0.0,.65,p.progress)*cover;
  float3 original=sharp.sample(s,in.uv).rgb;
  // Local optical refraction follows the advancing glass lip, not page geometry.
  float lipDistance=in.uv.y-(edge-feather*.72);
  float rim=exp(-pow(lipDistance/.026,2.0));
  float2 refractedUV=in.uv+float2((in.uv.x-.5)*.005,-.010)*rim*haze;
  float3 fine=mix(original,lightBlur.sample(s,refractedUV).rgb,smoothstep(0.0,.55,haze));
  float3 frost=mix(fine,blurred.sample(s,refractedUV).rgb,.70*smoothstep(.25,1.0,haze));
  float3 color=mix(original,frost,.88);
  // Diffuse transmission only: no moving specular band or illuminated edge.
  // Coverage and refraction still follow the lid, with a soft natural boundary.
  color+=(1-color)*(.025*haze)*float3(.90,.97,1.0);
  return float4(color,1);
 }

 float3 n=normalize(cross(dfdx(in.world),dfdy(in.world)));float tilt=1-abs(n.z);
 float localFold=p.mode<.5 ? (in.uv.y<.5 ? 1.0 : 0.0) : 1.0;
 // Only the folding upper panel is frosted. The lower panel is always sharp.
 // Frost builds with the physical fold; the hinge transitions more gently than the outer edge.
 float hingeDistance=clamp((.5-in.uv.y)*2,0.0,1.0);
 float materialDepth=p.mode<.5 ? mix(.72,1.0,smoothstep(0.0,.35,hingeDistance)) : 1.0;
 float haze=min(1.0,p.softness*1.5)*smoothstep(.0,.20,p.progress)*localFold*materialDepth;
 // Two blur scales prevent sharp text from lingering over a fully blurred duplicate.
 float3 fine=mix(sharp.sample(s,in.uv).rgb,lightBlur.sample(s,in.uv).rgb,smoothstep(0.0,.45,haze));
 float3 c=mix(fine,blurred.sample(s,in.uv).rgb,smoothstep(.22,1.0,haze));
 c=mix(c,float3(.78,.81,.83),haze*.075);
 // A restrained moving sheen follows the hinge; no overlay or crease at rest.
 float sheen=pow(1-abs(n.z),3.0)*haze*.035;
 c+=sheen;

 float3 facing=n*(n.z<0?-1.0:1.0);
 float directional=.5-.5*dot(facing,normalize(float3(-.35,.75,1)));
 float light=1-p.shadow*smoothstep(0.0,.3,p.progress)*(tilt*.25+directional*.45+p.progress*.05);
 if(!front && p.mode>3.5)c=float3(.035)+float3(.14)*pow(abs(n.z),10.0);
 else if(p.mode>=.5 || in.uv.y<.5)c*=max(.65,light)*(front?1.0:.92);
 // Keep the upper panel's captured content visible through frosting, including its back.
 // No fade-to-black multiplier for Duo.
 // Contact shadow falls on the fixed lower panel as the upper panel approaches.
 if(p.mode<.5 && in.uv.y>=.5){
  float a=p.padding>=0 ? p.padding : p.progress*3.14159265;
  float reach=max(0.0,-cos(a));
  float d=(in.uv.y-.5)*2;
  float contact=(1-smoothstep(reach,reach+.08,d))*smoothstep(1.5708,3.14159,a);
  c*=1-contact*p.shadow*.45;
 }
 return float4(c,1);
}
