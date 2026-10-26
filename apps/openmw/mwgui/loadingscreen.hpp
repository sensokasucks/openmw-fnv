#ifndef MWGUI_LOADINGSCREEN_H
#define MWGUI_LOADINGSCREEN_H

#include <memory>

#include <osg/Timer>
#include <osg/ref_ptr>

#include "windowbase.hpp"

#include <components/loadinglistener/loadinglistener.hpp>

namespace osgViewer
{
    class Viewer;
}

namespace osg
{
    class Texture2D;
}

namespace Resource
{
    class ResourceSystem;
}

namespace MWGui
{
    class BackgroundImage;
    class CopyFramebufferToTextureCallback;

    class LoadingScreen : public WindowBase, public Loading::Listener
    {
    public:
        LoadingScreen(Resource::ResourceSystem* resourceSystem, osgViewer::Viewer* viewer);
        virtual ~LoadingScreen();

        /// Overridden from Loading::Listener, see the Loading::Listener documentation for usage details
        void setLabel(const std::string& label, bool important) override;
        void loadingOn() override;
        void loadingOff() override;
        void setProgressRange(size_t range) override;
        void setProgress(size_t value) override;
        void increaseProgress(size_t increase = 1) override;

        void setVisible(bool visible) override;

        /// FO3/FNV content: FNV's loading backdrop on every loading screen, without Morrowind's progress box
        void setFalloutStyle(bool enabled);
        /// The content is loaded: FNV loading screens show a tip from the LSCR records from now on
        void setTipsReady() { mTipsReady = true; }

        double getTargetFrameRate() const;

    private:
        void findSplashScreens();
        bool needToDrawLoadingScreen();

        void setupCopyFramebufferToTextureCallback();

        Resource::ResourceSystem* mResourceSystem;
        osg::ref_ptr<osgViewer::Viewer> mViewer;

        double mTargetFrameRate;

        double mLastWallpaperChangeTime;
        double mLastRenderTime;
        osg::Timer mTimer;
        double mLoadingOnTime;

        bool mImportantLabel;

        int mNestedLoadingCount;

        size_t mProgress;

        bool mShowWallpaper;
        bool mFalloutStyle = false;
        bool mTipsReady = false;
        std::string mTipPicture; // the shown tip's picture, which the wallpaper changes keep
        MyGUI::ImageBox* mTipBar = nullptr;
        MyGUI::EditBox* mTipText = nullptr;

        void showTip();
        double mOldIcoMin = 0.0;
        unsigned int mOldIcoMax = 0;

        MyGUI::Widget* mLoadingBox;

        MyGUI::TextBox* mLoadingText;
        MyGUI::ScrollBar* mProgressBar;
        BackgroundImage* mSplashImage;
        BackgroundImage* mSceneImage;

        std::vector<std::string> mSplashScreens;

        osg::ref_ptr<osg::Texture2D> mTexture;
        osg::ref_ptr<CopyFramebufferToTextureCallback> mCopyFramebufferToTextureCallback;
        std::unique_ptr<MyGUI::ITexture> mGuiTexture;

        void changeWallpaper();

        void draw();
    };

}

#endif
