{-# LANGUAGE CPP #-}

module Main (main) where

#if (defined(MIN_VERSION_base) && MIN_VERSION_base(4,8,0))
#else
import Control.Applicative (pure, (<$>))
#endif

import Control.Exception (bracket_, onException)
import Control.Monad
import Data.Maybe
#if (defined(MIN_VERSION_base) && MIN_VERSION_base(4,11,0))
#else
import Data.Semigroup ((<>))
#endif
import SimpleCabal
import SimpleCmd
import SimpleCmd.Git
import SimpleCmdArgs
import System.Directory
import System.FilePath
import Paths_hkgr (version)

main :: IO ()
main =
  simpleCmdArgs (Just version) "Hackage Release tool"
  "'Hackager' is a package release tool for easy Hackage workflow" $
  subcommands
  [ Subcommand "tagdist" "'git tag' version and 'cabal sdist' tarball" $
    tagDistCmd <$> forceOpt "Move existing tag" <*> lintOpt
  , Subcommand "upload" "'cabal upload' candidate tarball to Hackage" $ (pure $ uploadCmd False) <*> lintOpt
  , Subcommand "publish" "Publish to Hackage ('cabal upload --publish')" $
    (pure $ uploadCmd True) <*> lintOpt
  , Subcommand "upload-haddock" "Upload candidate documentation to Hackage" $ pure $ upHaddockCmd False
  , Subcommand "publish-haddock" "Publish documentation to Hackage" $ pure $ upHaddockCmd True
  , Subcommand "version" "Show the package version from .cabal file" $
    pure showVersionCmd
  ]
  where
    forceOpt = switchWith 'f' "force"
    lintOpt = switchWith 'l' "lint" "Run hlint before proceeding"

tagDistCmd :: Bool -> Bool -> IO ()
tagDistCmd force lint = do
  when lint $ do
    mhlint <- findExecutable "hlint"
    when (isJust mhlint) $ cmd_ "hlint" ["."]
  git_ "diff" []
  pkgid <- getPackageId
  checkNotPublished pkgid
  let tag = packageVersion pkgid
  tagHash <- cmdMaybe "git" ["rev-parse", tag]
  when (isJust tagHash && not force) $
    error' "tag exists: use --force to override"
  git_ "tag" $ ["--force" | force] ++ [tag]
  unless force $ putStrLn tag
  sdist force pkgid `onException` do
    putStrLn "Resetting tag"
    if force
      then git_ "tag" ["--force", tag, fromJust tagHash]
      else git_ "tag" ["--delete", tag]

checkNotPublished :: PackageIdentifier -> IO ()
checkNotPublished pkgid = do
  let published = "dist" </> showPkgId pkgid <.> ".tar.gz" <.> "published"
  exists <- doesFileExist published
  when exists $ error' $ showPkgId pkgid <> " was already published!!"

sdist :: Bool -> PackageIdentifier -> IO ()
sdist force pkgid = do
  let ver = packageVersion pkgid
  let target = "dist" </> showPkgId pkgid <.> ".tar.gz"
  haveTarget <- doesFileExist target
  when haveTarget $
    if force
    then removeFile target
    else error' $ target <> " exists already!"
  cwd <- getCurrentDirectory
  withTempDirectory "tmp-sdist" $ do
    git_ "clone" ["-q", "--no-checkout", "..", "."]
    git_ "checkout" ["-q", ver]
    cabal_ "check" []
    cabal_ "configure" []
    -- cabal_ "build" []
    cabal_ "sdist" []
    renameFile target (cwd </> target)

showVersionCmd :: IO ()
showVersionCmd = do
  pkgid <- getPackageId
  putStrLn $ packageVersion pkgid

uploadCmd :: Bool -> Bool -> IO ()
uploadCmd publish lint = do
  pkgid <- getPackageId
  checkNotPublished pkgid
  let file = "dist" </> showPkgId pkgid <.> ".tar.gz"
  exists <- doesFileExist file
  unless exists $ tagDistCmd False lint
  cabal_ "upload" $ ["--publish" | publish] ++ [file]
  when publish $ do
    createFileLink (takeFileName file) (file <.> "published")
    git_ "push" ["--follow-tags"]

upHaddockCmd :: Bool -> IO ()
upHaddockCmd publish =
  cabal_ "upload" $ "--documentation" : ["--publish" | publish]

cabal_ :: String -> [String] -> IO ()
cabal_ c args =
  cmd_ "cabal" (c:args)

withTempDirectory :: FilePath -> IO a -> IO a
withTempDirectory dir run =
  bracket_ (createDirectory dir) (removeDirectoryRecursive dir) $
  withCurrentDirectory dir run
