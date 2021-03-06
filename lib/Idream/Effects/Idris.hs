
{-# LANGUAGE RankNTypes #-}

module Idream.Effects.Idris ( Idris(..), IdrisError(..)
                            , Command, Arg, Environment
                            , idrisGetLibDir
                            , idrisGetDocsDir
                            , idrisCompile
                            , idrisMkDocs
                            , runIdris
                            ) where

-- Imports

import Control.Monad.Freer
import Control.Monad ( void )
import Control.Exception ( IOException )
import System.Exit ( ExitCode(..) )
import System.Process ( createProcess, waitForProcess, cwd, env
                      , std_out, std_err, proc, StdStream (CreatePipe) )
import GHC.IO.Handle ( hGetContents )
import System.Environment ( getEnv )
import System.Directory ( makeAbsolute )
import Idream.SafeIO
import Idream.Types ( ProjectName(..), PackageName(..) )
import Idream.FilePaths
import Idream.ToText
import Data.Monoid ( (<>) )
import Data.Maybe ( fromJust )
import qualified Data.Text as T


-- Data types

data Idris a where
  IdrisGetLibDir :: Idris Directory
  IdrisGetDocsDir :: Idris Directory
  IdrisCompile :: ProjectName -> PackageName -> Idris ()
  IdrisMkDocs :: ProjectName -> PackageName -> Idris ()

data IdrisError = IdrGetLibDirErr IOException
                | IdrGetDocsDirErr IOException
                | IdrCompileErr ProjectName PackageName IOException
                | IdrMkDocsErr ProjectName PackageName IOException
                | IdrCommandErr Command ExitCode String
                | IdrAbsPathErr IOException
                deriving (Eq, Show)


-- | Type alias for command when spawning an external OS process.
type Command = String

-- | Type alias for command line arguments when spawning an external OS process.
type Arg = String

-- | Type alias for an environment to be passed to a command,
--   expressed as a list of key value pairs.
type Environment = [(String, String)]


-- Instances

instance ToText IdrisError where
  toText (IdrGetLibDirErr err) =
    "Failed to get lib directory for Idris packages, reason: "
      <> toText err <> "."
  toText (IdrGetDocsDirErr err) =
    "Failed to get docs directory for Idris packages, reason: "
      <> toText err <> "."
  toText (IdrCompileErr projName pkgName err) =
    "Failed to compile idris package (project = "
      <> toText projName <> ", package = " <> toText pkgName
      <> "), reason: " <> toText err <> "."
  toText (IdrMkDocsErr projName pkgName err) =
    "Failed to generate docs for idris package (project = "
      <> toText projName <> ", package = " <> toText pkgName
      <> "), reason: " <> toText err <> "."
  toText (IdrCommandErr cmd exitCode errOutput) =
    "Failed to invoke idris (command: " <> toText cmd
      <> "), exit code = " <> T.pack (show exitCode)
      <> ", error output:\n" <> toText errOutput
  toText (IdrAbsPathErr err) =
    "Failed to compute absolute file path, reason: " <> toText err


-- Functions

idrisGetLibDir :: Member Idris r => Eff r Directory
idrisGetLibDir = send IdrisGetLibDir

idrisGetDocsDir :: Member Idris r => Eff r Directory
idrisGetDocsDir = send IdrisGetDocsDir

idrisCompile :: Member Idris r
             => ProjectName -> PackageName -> Eff r ()
idrisCompile projName pkgName = send $ IdrisCompile projName pkgName

idrisMkDocs :: Member Idris r
            => ProjectName -> PackageName -> Eff r ()
idrisMkDocs projName pkgName = send $ IdrisMkDocs projName pkgName

runIdris :: forall e r. LastMember (SafeIO e) r
         => (IdrisError -> e) -> Eff (Idris ': r) ~> Eff r
runIdris f = interpretM g where
  g :: Idris ~> SafeIO e
  g IdrisGetLibDir = do
    let eh1 = f . IdrGetLibDirErr
        eh2 ec err = f $ IdrCommandErr "get lib dir" ec err
        idrisArgs = [ "--libdir" ]
        toDir = filter (/= '\n')
    toDir <$> invokeIdrisWithEnv eh1 eh2 idrisArgs Nothing []
  g IdrisGetDocsDir = do
    let eh1 = f . IdrGetDocsDirErr
        eh2 ec err = f $ IdrCommandErr "get docs dir" ec err
        idrisArgs = [ "--docdir" ]
        toDir = filter (/= '\n')
    toDir <$> invokeIdrisWithEnv eh1 eh2 idrisArgs Nothing []
  g (IdrisCompile projName pkgName) = do
    absCompileDir <- absPath (f . IdrAbsPathErr) compileDir
    let buildDir' = pkgBuildDir projName pkgName
        ipkg = fromJust $ ipkgFile projName pkgName `relativeTo` buildDir'
        idrisCompileArgs = [ "--verbose", "--build", ipkg]
        idrisInstallArgs = [ "--verbose", "--install", ipkg]
        environ = [ ("IDRIS_LIBRARY_PATH", absCompileDir) ]
        eh1 = f . IdrCompileErr projName pkgName
        eh2 ec err = f $ IdrCommandErr ("compile " ++ unwords idrisCompileArgs) ec err
        eh3 ec err = f $ IdrCommandErr ("install " ++ unwords idrisInstallArgs) ec err
    void $ invokeIdrisWithEnv eh1 eh2 idrisCompileArgs (Just buildDir') environ
    void $ invokeIdrisWithEnv eh1 eh3 idrisInstallArgs (Just buildDir') environ
  g (IdrisMkDocs projName pkgName) = do
    absDocsDir <- absPath (f . IdrAbsPathErr) docsDir
    absCompileDir <- absPath (f . IdrAbsPathErr) compileDir
    let buildDir' = pkgBuildDir projName pkgName
        ipkg = fromJust $ ipkgFile projName pkgName `relativeTo` buildDir'
        idrisMkDocsArgs = [ "--verbose", "--mkdoc", ipkg]
        idrisInstallDocsArgs = [ "--verbose", "--installdoc", ipkg]
        environ = [ ("IDRIS_LIBRARY_PATH", absCompileDir)
                  , ("IDRIS_DOC_PATH", absDocsDir) ]
        eh1 = f . IdrMkDocsErr projName pkgName
        eh2 ec err = f $ IdrCommandErr ("mkdoc " ++ unwords idrisMkDocsArgs) ec err
        eh3 ec err = f $ IdrCommandErr ("installdoc " ++ unwords idrisInstallDocsArgs) ec err
    void $ invokeIdrisWithEnv eh1 eh2 idrisMkDocsArgs (Just buildDir') environ
    void $ invokeIdrisWithEnv eh1 eh3 idrisInstallDocsArgs (Just buildDir') environ


-- | Converts a relative path into an absolute path.
absPath :: (IOException -> e) -> FilePath -> SafeIO e FilePath
absPath f path = liftSafeIO f $ makeAbsolute path

-- | Invokes a command as a separate operating system process.
--   Allows passing additional environment variables to the external process.
invokeCmdWithEnv :: (IOException -> e)
                 -> (ExitCode -> String -> e)
                 -> Command -> [Arg] -> Maybe Directory -> Environment
                 -> SafeIO e String
invokeCmdWithEnv f g cmd cmdArgs maybeWorkDir environ = do
  result <- liftSafeIO f $ do
    homeDir <- getEnv "HOME"
    let environ' = ("HOME", homeDir) : environ
        process = (proc cmd cmdArgs) { cwd = maybeWorkDir, env = Just environ'
                                     , std_out = CreatePipe, std_err = CreatePipe }
    (_, stdOut, stdErr, procHandle) <- createProcess process
    result <- waitForProcess procHandle
    if result /= ExitSuccess
      then do output <- hGetContents $ fromJust stdOut
              errOutput <- hGetContents $ fromJust stdErr
              return $ Left (g result $ output ++ errOutput)
      else do output <- hGetContents $ fromJust stdOut
              return $ Right output
  either raiseError return result

-- | Invokes the Idris compiler as a separate operating system process.
--   Allows passing additional environment variables to the external process.
invokeIdrisWithEnv :: (IOException -> e)
                   -> (ExitCode -> String -> e)
                   -> [Arg] -> Maybe Directory -> Environment
                   -> SafeIO e String
invokeIdrisWithEnv f g = invokeCmdWithEnv f g "idris"

