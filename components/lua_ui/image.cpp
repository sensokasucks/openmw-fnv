#include "image.hpp"

#include <utility>

#include <MyGUI_RenderManager.h>

#include "resources.hpp"

namespace LuaUi
{
    void LuaTileRect::_setAlign(const MyGUI::IntSize& /*oldSize*/)
    {
        mCoord.set(0, 0, mCroppedParent->getWidth(), mCroppedParent->getHeight());
        mTileSize = mSetTileSize;

        // zero tilesize stands for not tiling
        if (mTileSize.width == 0)
            mTileSize.width = mCoord.width;
        if (mTileSize.height == 0)
            mTileSize.height = mCoord.height;

        // mCoord could be zero, prevent division by 0
        // use arbitrary large numbers to prevent performance issues
        if (mTileSize.width <= 0)
            mTileSize.width = 10000000;
        if (mTileSize.height <= 0)
            mTileSize.height = 10000000;

        MyGUI::TileRect::_updateView();
    }

    void LuaImage::initialize()
    {
        changeWidgetSkin("LuaImage");
        mTileRect = dynamic_cast<LuaTileRect*>(getSubWidgetMain());
        WidgetExtension::initialize();
    }

    void LuaImage::updateProperties()
    {
        deleteAllItems();
        TextureResource* resource = propertyValue<TextureResource*>("resource", nullptr);
        MyGUI::IntCoord atlasCoord;
        // a negative size shows the region mirrored (render targets are stored bottom row first)
        bool flipH = false;
        bool flipV = false;
        if (resource)
        {
            flipH = resource->mSize.x() < 0;
            flipV = resource->mSize.y() < 0;
            int width = static_cast<int>(resource->mSize.x());
            int height = static_cast<int>(resource->mSize.y());
            int x = static_cast<int>(resource->mOffset.x());
            int y = static_cast<int>(resource->mOffset.y());
            if (flipH)
            {
                x += width;
                width = -width;
            }
            if (flipV)
            {
                y += height;
                height = -height;
            }
            atlasCoord = MyGUI::IntCoord(x, y, width, height);
            setImageTexture(resource->mPath);
        }

        bool tileH = propertyValue("tileH", false);
        bool tileV = propertyValue("tileV", false);

        MyGUI::ITexture* texture = MyGUI::RenderManager::getInstance().getTexture(_getTextureName());
        MyGUI::IntSize textureSize;
        if (texture != nullptr)
            textureSize = MyGUI::IntSize(texture->getWidth(), texture->getHeight());

        if (atlasCoord.width == 0)
            atlasCoord.width = textureSize.width;
        if (atlasCoord.height == 0)
            atlasCoord.height = textureSize.height;

        mTileRect->updateSize(MyGUI::IntSize(tileH ? atlasCoord.width : 0, tileV ? atlasCoord.height : 0));
        setImageTile(atlasCoord.size());
        setImageCoord(atlasCoord);
        if ((flipH || flipV) && textureSize.width > 0 && textureSize.height > 0)
        {
            float left = static_cast<float>(atlasCoord.left) / textureSize.width;
            float right = static_cast<float>(atlasCoord.right()) / textureSize.width;
            float top = static_cast<float>(atlasCoord.top) / textureSize.height;
            float bottom = static_cast<float>(atlasCoord.bottom()) / textureSize.height;
            if (flipH)
                std::swap(left, right);
            if (flipV)
                std::swap(top, bottom);
            mTileRect->_setUVSet(MyGUI::FloatRect(left, top, right, bottom));
        }

        setColour(propertyValue("color", MyGUI::Colour(1, 1, 1, 1)));

        WidgetExtension::updateProperties();
    }

    const std::vector<std::string_view>& LuaImage::allUsedProperties() const
    {
        static std::vector<std::string_view> usedProps = std::invoke([this] {
            std::vector<std::string_view> props = { "resource", "tileH", "tileV", "color" };
            auto baseProps = WidgetExtension::allUsedProperties();
            props.insert(props.end(), baseProps.begin(), baseProps.end());
            return props;
        });
        return usedProps;
    }
}
