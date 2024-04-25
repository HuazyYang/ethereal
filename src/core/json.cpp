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

/*
License for JsonCpp

JsonCpp is Public Domain

The JsonCpp library's source code, including accompanying documentation, 
tests and demonstration applications, are licensed under the following
conditions...

Baptiste Lepilleur and The JsonCpp Authors explicitly disclaim copyright in all 
jurisdictions which recognize such a disclaimer. In such jurisdictions, 
this software is released into the Public Domain.
*/
#include <array>
#include <ethereal/core/json.h>
#include <ethereal/core/vfs/VFS.h>
#include <ethereal/core/log.h>
#include <exception>
#include <nlohmann/json.hpp>
#include <string>

using namespace ethereal::math;
using namespace ethereal::vfs;

namespace ethereal::json
{
    bool LoadFromFile(IFileSystem& fs, const std::filesystem::path& jsonFileName, nlohmann::json& documentRoot)
    {
        std::shared_ptr<IBlob> data = fs.readFile(jsonFileName);
        if (!data)
        {
            log::error("Couldn't read file %s", jsonFileName.generic_string().c_str());
            return false;
        }

        try {
        documentRoot = nlohmann::json::parse((const char *)data->data(), (const char *)data->data() + data->size(), nullptr, true, true);
        } catch(std::exception &e) {
            log::error("Parse JSON file: \"%s\" error: %s", jsonFileName.generic_string().c_str(), e.what());
            return false;
        }

        return true;
    }

    template<>
    std::string Read<std::string>(const nlohmann::json& node, const std::string& defaultValue)
    {
        if (node.is_string())
            return node.get<std::string>();

        return defaultValue;
    }

    template<>
    int Read<int>(const nlohmann::json& node, const int& defaultValue)
    {
        if (node.is_number())
            return node.get<int>();

        return defaultValue;
    }

    template<>
    int2 Read<int2>(const nlohmann::json& node, const int2& defaultValue)
    {
        if (node.is_array() && node.size() == 2)
            return int2(node[0].get<int>(), node[1].get<int>());

        if (node.is_number())
            return node.get<int>();

        return defaultValue;
    }

    template<>
    int3 Read<int3>(const nlohmann::json& node, const int3& defaultValue)
    {
        if (node.is_array() && node.size() == 3)
            return int3(node[0].get<int>(), node[1].get<int>(), node[2].get<int>());

        if (node.is_number())
            return node.get<int>();

        return defaultValue;
    }

    template<>
    int4 Read<int4>(const nlohmann::json& node, const int4& defaultValue)
    {
        if (node.is_array() && node.size() == 4)
            return int4(node[0].get<int>(), node[1].get<int>(), node[2].get<int>(), node[3].get<int>());

        if (node.is_number())
            return node.get<int>();

        return defaultValue;
    }

    template<>
    uint Read<uint>(const nlohmann::json& node, const uint& defaultValue)
    {
        if (node.is_number())
            return node.get<uint>();

        return defaultValue;
    }

    template<>
    uint2 Read<uint2>(const nlohmann::json& node, const uint2& defaultValue)
    {
        if (node.is_array() && node.size() == 2)
            return uint2(node[0].get<uint>(), node[1].get<uint>());

        if (node.is_number())
            return node.get<uint>();

        return defaultValue;
    }

    template<>
    uint3 Read<uint3>(const nlohmann::json& node, const uint3& defaultValue)
    {
        if (node.is_array() && node.size() == 3)
            return uint3(node[0].get<uint>(), node[1].get<uint>(), node[2].get<uint>());

        if (node.is_number())
            return node.get<uint>();

        return defaultValue;
    }

    template<>
    uint4 Read<uint4>(const nlohmann::json& node, const uint4& defaultValue)
    {
        if (node.is_array() && node.size() == 4)
            return uint4(node[0].get<uint>(), node[1].get<uint>(), node[2].get<uint>(), node[3].get<uint>());

        if (node.is_number())
            return node.get<uint>();

        return defaultValue;
    }

    template<>
    bool Read<bool>(const nlohmann::json& node, const bool& defaultValue)
    {
        if (node.is_boolean())
            return node.get<bool>();

        if (node.is_number())
            return node.get<float>() != 0.f;

        return defaultValue;
    }

    template<>
    float Read<float>(const nlohmann::json& node, const float& defaultValue)
    {
        if (node.is_number())
            return node.get<float>();

        return defaultValue;
    }

    template<>
    float2 Read<float2>(const nlohmann::json& node, const float2& defaultValue)
    {
        if (node.is_array() && node.size() == 2)
            return float2(node[0].get<float>(), node[1].get<float>());

        if (node.is_number())
            return node.get<float>();

        return defaultValue;
    }

    template<>
    float3 Read<float3>(const nlohmann::json& node, const float3& defaultValue)
    {
        if (node.is_array() && node.size() == 3)
            return float3(node[0].get<float>(), node[1].get<float>(), node[2].get<float>());

        if (node.is_number())
            return node.get<float>();

        return defaultValue;
    }

    template<>
    float4 Read<float4>(const nlohmann::json& node, const float4& defaultValue)
    {
        if (node.is_array() && node.size() == 4)
            return float4(node[0].get<float>(), node[1].get<float>(), node[2].get<float>(), node[3].get<float>());

        if (node.is_number())
            return node.get<float>();

        return defaultValue;
    }

    template<>
    double Read<double>(const nlohmann::json& node, const double& defaultValue)
    {
        if (node.is_number())
            return node.get<double>();

        return defaultValue;
    }

    template<>
    double2 Read<double2>(const nlohmann::json& node, const double2& defaultValue)
    {
        if (node.is_array() && node.size() == 2)
            return double2(node[0].get<double>(), node[1].get<double>());

        if (node.is_number())
            return node.get<double>();

        return defaultValue;
    }

    template<>
    double3 Read<double3>(const nlohmann::json& node, const double3& defaultValue)
    {
        if (node.is_array() && node.size() == 3)
            return double3(node[0].get<double>(), node[1].get<double>(), node[2].get<double>());

        if (node.is_number())
            return node.get<double>();

        return defaultValue;
    }

    template<>
    double4 Read<double4>(const nlohmann::json& node, const double4& defaultValue)
    {
        if (node.is_array() && node.size() == 4)
            return double4(node[0].get<double>(), node[1].get<double>(), node[2].get<double>(), node[3].get<double>());

        if (node.is_number())
            return node.get<double>();

        return defaultValue;
    }

    template <>
    void Write<std::string>(nlohmann::json& node, const std::string& value)
    {
        node = value;
    }

    template <>
    void Write<int>(nlohmann::json& node, const int& value)
    {
        node = value;
    }

    template<typename T, int N>
    static void WriteVector(nlohmann::json &node, const dm::vector<T, N> &value) {
        auto &v = reinterpret_cast<const std::array<T, N>&>(value);
        node = v;
    }

    template <>
    void Write<int2>(nlohmann::json& node, const dm::int2& value)
    {
        WriteVector(node, value);
    }

    template <>
    void Write<int3>(nlohmann::json& node, const dm::int3& value)
    {
        WriteVector(node, value);
    }

    template <>
    void Write<int4>(nlohmann::json& node, const dm::int4& value)
    {
        WriteVector(node, value);
    }

    template <>
    void Write<uint>(nlohmann::json& node, const uint& value)
    {
        node = value;
    }

    template <>
    void Write<uint2>(nlohmann::json& node, const dm::uint2& value)
    {
        WriteVector(node, value);
    }

    template <>
    void Write<uint3>(nlohmann::json& node, const dm::uint3& value)
    {
        WriteVector(node, value);
    }

    template <>
    void Write<uint4>(nlohmann::json& node, const dm::uint4& value)
    {
        WriteVector(node, value);
    }

    template <>
    void Write<bool>(nlohmann::json& node, const bool& value)
    {
        node = value;
    }

    template <>
    void Write<float>(nlohmann::json& node, const float& value)
    {
        node = value;
    }

    template <>
    void Write<float2>(nlohmann::json& node, const dm::float2& value)
    {
        WriteVector(node, value);
    }

    template <>
    void Write<float3>(nlohmann::json& node, const dm::float3& value)
    {
        WriteVector(node, value);
    }

    template <>
    void Write<float4>(nlohmann::json& node, const dm::float4& value)
    {
        WriteVector(node, value);
    }

    template <>
    void Write<double>(nlohmann::json& node, const double& value)
    {
        node = value;
    }

    template <>
    void Write<double2>(nlohmann::json& node, const dm::double2& value)
    {
        WriteVector(node, value);
    }

    template <>
    void Write<double3>(nlohmann::json& node, const dm::double3& value)
    {
        WriteVector(node, value);
    }

    template <>
    void Write<double4>(nlohmann::json& node, const dm::double4& value)
    {
        WriteVector(node, value);
    }
}

void operator<<(nlohmann::json& node, const char* src)
{
    node = src;
}
