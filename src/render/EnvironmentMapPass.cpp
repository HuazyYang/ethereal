/*
* Copyright (c) 2014-2021, NVIDIA CORPORATION. All rights reserved.
*
* Permission is hereby granted, free of charge, to any person obtaining a
* copy of this software and associated documentation files (the "Software"),
* to deal in the Software without restriction, including without limitation
* the rights to use, copy, modify, merge, publish, distribute, sublicense,
* and/or sell copies of the Software, and to permit persons to whom the
* Software is furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in
* all copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
* THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
* FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
* DEALINGS IN THE SOFTWARE.
*/

#include <ethereal/render/EnvironmentMapPass.h>
#include <ethereal/engine/FramebufferFactory.h>
#include <ethereal/engine/ShaderFactory.h>
#include <ethereal/engine/CommonRenderPasses.h>
#include <ethereal/engine/View.h>
#include <ethereal/core/math/math.h>

#if ETHEREAL_WITH_STATIC_SHADERS
#if ETHEREAL_WITH_DX11
#include "compiled_shaders/passes/environment_map_ps.dxbc.h"
#endif
#if ETHEREAL_WITH_DX12
#include "compiled_shaders/passes/environment_map_ps.dxil.h"
#endif
#if ETHEREAL_WITH_VULKAN
#include "compiled_shaders/passes/environment_map_ps.spirv.h"
#endif
#endif

using namespace ethereal::math;
#include <ethereal/shaders/sky_cb.h>

using namespace ethereal::engine;
using namespace ethereal::render;

EnvironmentMapPass::EnvironmentMapPass(
    nvrhi::IDevice* device,
    std::shared_ptr<ShaderFactory> shaderFactory,
    std::shared_ptr<CommonRenderPasses> commonPasses,
    std::shared_ptr<FramebufferFactory> framebufferFactory,
    const ICompositeView& compositeView,
    nvrhi::ITexture* environmentMap)
    : m_CommonPasses(commonPasses)
    , m_FramebufferFactory(framebufferFactory)
{
    nvrhi::TextureDimension envMapDimension = environmentMap->getDesc().dimension;
    bool isCubeMap = (envMapDimension == nvrhi::TextureDimension::TextureCube) || 
        (envMapDimension == nvrhi::TextureDimension::TextureCubeArray);

    std::vector<engine::ShaderMacro> PSMacros;
    PSMacros.push_back(engine::ShaderMacro("LATLONG_TEXTURE", isCubeMap ? "0" : "1"));

    m_PixelShader = shaderFactory->CreateAutoShader("ethereal/passes/environment_map_ps.hlsl", "main", 
        ETHEREAL_MAKE_PLATFORM_SHADER(g_environment_map_ps), &PSMacros, nvrhi::ShaderType::Pixel);

    nvrhi::BufferDesc constantBufferDesc;
    constantBufferDesc.byteSize = sizeof(SkyConstants);
    constantBufferDesc.debugName = "SkyConstants";
    constantBufferDesc.isConstantBuffer = true;
    constantBufferDesc.isVolatile = true;
    constantBufferDesc.maxVersions = engine::c_MaxRenderPassConstantBufferVersions;
    m_SkyCB = device->createBuffer(constantBufferDesc);

    const IView* sampleView = compositeView.GetChildView(ViewType::PLANAR, 0);
    nvrhi::IFramebuffer* sampleFramebuffer = m_FramebufferFactory->GetFramebuffer(*sampleView);

    {
        nvrhi::BindingLayoutDesc layoutDesc;
        layoutDesc.visibility = nvrhi::ShaderType::Pixel;
        layoutDesc.bindings = {
            nvrhi::BindingLayoutItem::VolatileConstantBuffer(0),
            nvrhi::BindingLayoutItem::Texture_SRV(0),
            nvrhi::BindingLayoutItem::Sampler(0)
        };
        m_RenderBindingLayout = device->createBindingLayout(layoutDesc);

        nvrhi::BindingSetDesc bindingSetDesc;
        bindingSetDesc.bindings = {
            nvrhi::BindingSetItem::ConstantBuffer(0, m_SkyCB),
            nvrhi::BindingSetItem::Texture_SRV(0, environmentMap),
            nvrhi::BindingSetItem::Sampler(0, commonPasses->m_LinearWrapSampler)
        };
        m_RenderBindingSet = device->createBindingSet(bindingSetDesc, m_RenderBindingLayout);

        nvrhi::GraphicsPipelineDesc pipelineDesc;
        pipelineDesc.primType = nvrhi::PrimitiveType::TriangleStrip;
        pipelineDesc.VS = sampleView->IsReverseDepth() ? m_CommonPasses->m_FullscreenVS : m_CommonPasses->m_FullscreenAtOneVS;
        pipelineDesc.PS = m_PixelShader;
        pipelineDesc.bindingLayouts = { m_RenderBindingLayout };

        pipelineDesc.renderState.rasterState.setCullNone();
        pipelineDesc.renderState.depthStencilState
            .enableDepthTest()
            .disableDepthWrite()
            .disableStencil()
            .setDepthFunc(sampleView->IsReverseDepth()
                ? nvrhi::ComparisonFunc::GreaterOrEqual
                : nvrhi::ComparisonFunc::LessOrEqual);

        m_RenderPso = device->createGraphicsPipeline(pipelineDesc, sampleFramebuffer);
    }
}

void EnvironmentMapPass::Render(
    nvrhi::ICommandList* commandList,
    const ICompositeView& compositeView)
{
    commandList->beginMarker("Environment Map");

    for (uint viewIndex = 0; viewIndex < compositeView.GetNumChildViews(ViewType::PLANAR); viewIndex++)
    {
        const IView* view = compositeView.GetChildView(ViewType::PLANAR, viewIndex);

        nvrhi::GraphicsState state;
        state.pipeline = m_RenderPso;
        state.framebuffer = m_FramebufferFactory->GetFramebuffer(*view);
        state.bindings = { m_RenderBindingSet };
        state.viewport = view->GetViewportState();

        SkyConstants skyConstants = {};
        skyConstants.matClipToTranslatedWorld = view->GetInverseViewProjectionMatrix() * affineToHomogeneous(translation(-view->GetViewOrigin()));
        commandList->writeBuffer(m_SkyCB, &skyConstants, sizeof(skyConstants));

        commandList->setGraphicsState(state);

        nvrhi::DrawArguments args;
        args.instanceCount = 1;
        args.vertexCount = 4;
        commandList->draw(args);
    }

    commandList->endMarker();
}
