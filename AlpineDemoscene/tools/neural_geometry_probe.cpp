// CPU-only QA of the exact production mesh postprocess, using saved neural fields.
// Any output .vertices cache is development evidence, never a runtime asset.
#include <fstream>
#include <vector>
#include <filesystem>
#include <stdexcept>
#include <string>
#include <iostream>
#include <iomanip>
#include "../src/neural_avatar_runtime.cpp"
namespace fs=std::filesystem;
template<class T>std::vector<T> ReadFile(const fs::path& path){
    std::ifstream f(path,std::ios::binary|std::ios::ate);if(!f)throw std::runtime_error("Cannot read file");
    size_t bytes=size_t(f.tellg());if(bytes%sizeof(T)||bytes>400000000)throw std::runtime_error("Invalid file length");
    std::vector<T> v(bytes/sizeof(T));f.seekg(0);f.read((char*)v.data(),bytes);if(!f)throw std::runtime_error("Read failed");return v;
}
void WriteFile(const fs::path& p,const void* data,size_t bytes){std::ofstream f(p,std::ios::binary);f.write((const char*)data,bytes);if(!f)throw std::runtime_error("Write failed");}
static uint32_t cancelCalls=0;
static int CancelPump(){return ++cancelCalls<3;}
int main(int argc,char**argv)try{
    if(argc!=5)throw std::runtime_error("Usage: neural_geometry_probe body|head GPU_DUMP_DIR OUT_DIR SOURCE_CACHE_DIR");
    bool head=std::string(argv[1])=="head";if(!head&&std::string(argv[1])!="body")throw std::runtime_error("Unknown model kind");
    fs::path input=argv[2],out=argv[3],cache=argv[4];fs::create_directories(out);
    bool resampled=fs::exists(input/"extracted_positions.f32");
    auto field=ReadFile<float>(input/"field.f32");auto attr=ReadFile<float>(input/"attributes.f32");auto points=ReadFile<F3>(input/(resampled?"extracted_positions.f32":"positions.f32"));
    uint32_t nx=head?81:65,ny=head?97:129,nz=head?81:49,stride=head?32:12,vertexStride=head?36:16;
    if(field.size()!=nx*ny*nz)throw std::runtime_error("Field dimensions differ");
    F3 minimum=head?F3{-1,-1,-1}:F3{-1,-1.3f,-.35f};F3 step=head?F3{2.f/(nx-1),2.f/(ny-1),2.f/(nz-1)}:F3{2.f/(nx-1),2.2f/(ny-1),.7f/(nz-1)};
    Mesh mesh(field.data(),nx,ny,nz,minimum,step);
    if(!mesh.valid||!mesh.Build(nullptr)||!KeepLargestSurface(mesh,nullptr))throw std::runtime_error("Extraction failed");
    if(mesh.vertexCount!=points.size()||attr.size()!=mesh.vertexCount*stride)throw std::runtime_error("Baseline vertex correspondence differs");
    float correspondence=0;
    for(uint32_t i=0;i<mesh.vertexCount;++i){F3 d=Sub(mesh.positions[i],points[i]);correspondence=Maximum(correspondence,Root(Dot(d,d)));}
    if(correspondence>1e-5f)throw std::runtime_error("Baseline positions are not the original extraction");
    WriteFile(out/"indices.u32",mesh.indices,mesh.indexCount*4);
    WriteFile(out/"before.positions.f32",mesh.positions,mesh.vertexCount*sizeof(F3));
    WriteFile(out/"before.attributes.f32",attr.data(),attr.size()*4);
    if(!RefineNeuralGeometry(mesh,head,nullptr))throw std::runtime_error("Geometry refinement failed");
    float refinedCorrespondence=0;
    if(resampled){auto gpuPositions=ReadFile<F3>(input/"positions.f32");if(gpuPositions.size()!=mesh.vertexCount)throw std::runtime_error("Refined position count differs");
        for(uint32_t i=0;i<mesh.vertexCount;++i){F3 d=Sub(mesh.positions[i],gpuPositions[i]);refinedCorrespondence=Maximum(refinedCorrespondence,Root(Dot(d,d)));}
        if(refinedCorrespondence>1e-6f)throw std::runtime_error("Refined positions differ from runtime");}
    if(!RefineNeuralAttributes(mesh,attr.data(),head,nullptr)||!FilterNeuralClothingNormals(mesh,attr.data(),head,nullptr))throw std::runtime_error("Attribute refinement failed");
    WriteFile(out/"after.positions.f32",mesh.positions,mesh.vertexCount*sizeof(F3));
    WriteFile(out/"after.attributes.f32",attr.data(),attr.size()*4);
    WriteFile(out/"after.geometric_normals.f32",mesh.normals,mesh.vertexCount*sizeof(F3));
    F3 lo={1e20f,1e20f,1e20f},hi={-1e20f,-1e20f,-1e20f};
    for(uint32_t i=0;i<mesh.vertexCount;++i){F3 p=mesh.positions[i];lo={Minimum(lo.x,p.x),Minimum(lo.y,p.y),Minimum(lo.z,p.z)};hi={Maximum(hi.x,p.x),Maximum(hi.y,p.y),Maximum(hi.z,p.z)};}
    float height=head?.33f:1.75f,scale=height/Maximum(hi.y-lo.y,.1f);std::vector<float> vertices(mesh.indexCount*vertexStride);
    for(uint32_t i=0;i<mesh.indexCount;++i){uint32_t id=mesh.indices[i];float* a=attr.data()+id*stride;float* v=vertices.data()+i*vertexStride;F3 p=mesh.positions[id];
        v[0]=p.x*scale;v[1]=(p.y-lo.y)*scale;v[2]=p.z*scale;v[3]=1;
        F3 n={a[0],a[1],a[2]};if(Dot(n,mesh.normals[id])<0)n=Mul(n,-1);n=Normal(n);v[4]=n.x;v[5]=n.y;v[6]=n.z;
        for(uint32_t j=0;j<4;++j){uint32_t joint=uint32_t(a[4+j]);Copy(v+8+j,&joint,4);v[12+j]=a[8+j];}
        if(head){for(uint32_t j=0;j<3;++j)v[16+j]=a[12+j];v[19]=1;for(uint32_t j=0;j<16;++j)v[20+j]=a[16+j]*scale;}
    }
    std::string id=head?"202":"200";WriteFile(out/(id+".vertices"),vertices.data(),vertices.size()*4);
    float rig[128]={};
    if(!head&&!NeuralBindLandmarks(mesh,attr.data(),scale,lo.y,rig,nullptr))throw std::runtime_error("Generated rig calibration failed");
    WriteFile(out/(id+".rig"),rig,head?0:sizeof(rig));
    std::ifstream metadata(cache/(id+".meta"));std::string format,hash;uint32_t resource,seed,oldStride,oldVertices,motionFrames;float duration;
    metadata>>format>>resource>>seed>>hash>>oldStride>>oldVertices>>motionFrames>>duration;
    if(!metadata||oldStride!=vertexStride*4)throw std::runtime_error("Invalid baseline QA cache metadata");
    std::ofstream m(out/(id+".meta"));m<<std::setprecision(9)<<format<<'\n'<<resource<<' '<<seed<<' '<<hash<<'\n'<<vertexStride*4<<' '<<mesh.indexCount<<' '<<motionFrames<<' '<<duration<<'\n'
        <<lo.x*scale<<" 0 "<<lo.z*scale<<' '<<hi.x*scale<<' '<<height<<' '<<hi.z*scale<<'\n';m.close();
    fs::copy_file(cache/(id+".motion"),out/(id+".motion"),fs::copy_options::overwrite_existing);
    cancelCalls=0;bool cancellation=!RefineNeuralGeometry(mesh,head,CancelPump);
    if(!head){cancelCalls=0;cancellation=cancellation&&!FilterNeuralClothingNormals(mesh,attr.data(),head,CancelPump);}
    std::ofstream report(out/"native.json");report<<std::setprecision(10)<<"{\"cpu_only\":true,\"kind\":\""<<(head?"head":"body")<<"\",\"unique_vertices\":"<<mesh.vertexCount<<",\"triangle_vertices\":"<<mesh.indexCount
        <<",\"baseline_correspondence_max\":"<<correspondence<<",\"scale\":"<<scale<<",\"cancellation_passed\":"<<(cancellation?"true":"false")
        <<",\"refined_position_runtime_max_error\":"<<refinedCorrespondence<<",\"attributes_resampled_at_new_positions\":"<<(resampled?"true":"false")
        <<",\"note\":\"QA cache only. Fresh dumps use attributes inferred at refined coordinates; legacy dumps retain original attributes to isolate postprocessing.\"}\n";
    std::cout<<"CPU geometry refinement complete: "<<mesh.vertexCount<<" vertices; cancellation="<<cancellation<<std::endl;
    return cancellation?0:1;
}catch(const std::exception&e){std::cerr<<e.what()<<std::endl;return 1;}
