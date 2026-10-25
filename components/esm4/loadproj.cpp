#include "loadproj.hpp"

#include <stdexcept>

#include "reader.hpp"

void ESM4::Projectile::load(ESM4::Reader& reader)
{
    mId = reader.getFormIdFromHeader();
    mFlags = reader.hdr().record.flags;

    while (reader.getSubRecordHeader())
    {
        const ESM4::SubRecordHeader& subHdr = reader.subRecordHeader();
        switch (subHdr.typeId)
        {
            case ESM::fourCC("EDID"):
                reader.getZString(mEditorId);
                break;
            case ESM::fourCC("FULL"):
                reader.getLocalizedString(mFullName);
                break;
            case ESM::fourCC("MODL"):
                reader.getZString(mModel);
                break;
            case ESM::fourCC("NAM1"):
                reader.getZString(mMuzzleFlashModel);
                break;
            case ESM::fourCC("VNAM"):
                reader.get(mSoundLevel);
                break;
            case ESM::fourCC("DATA"):
            {
                if (subHdr.dataSize < 52) // TES5 and later differ
                {
                    reader.skipSubRecordData();
                    break;
                }
                Data& d = mData;
                reader.get(d.flags);
                reader.get(d.type);
                reader.get(d.gravity);
                reader.get(d.speed);
                reader.get(d.range);
                reader.getFormId(d.light);
                reader.getFormId(d.muzzleFlashLight);
                reader.get(d.tracerChance);
                reader.get(d.explosionProximity);
                reader.get(d.explosionTimer);
                reader.getFormId(d.explosion);
                reader.getFormId(d.sound);
                reader.get(d.muzzleFlashDuration);
                reader.get(d.fadeDuration);
                if (subHdr.dataSize >= 84) // FONV
                {
                    reader.get(d.impactForce);
                    reader.getFormId(d.soundCountdown);
                    reader.getFormId(d.soundDisable);
                    reader.getFormId(d.defaultWeaponSource);
                    reader.get(d.rotation[0]);
                    reader.get(d.rotation[1]);
                    reader.get(d.rotation[2]);
                    reader.get(d.bouncyMult);
                    if (subHdr.dataSize > 84)
                        reader.skipSubRecordData(subHdr.dataSize - 84);
                }
                else
                    reader.skipSubRecordData(subHdr.dataSize - 52);
                break;
            }
            case ESM::fourCC("OBND"):
            case ESM::fourCC("MODB"):
            case ESM::fourCC("MODT"):
            case ESM::fourCC("MODS"):
            case ESM::fourCC("NAM2"): // muzzle flash model data
            case ESM::fourCC("DEST"): // destructible
            case ESM::fourCC("DSTD"):
            case ESM::fourCC("DSTF"):
            case ESM::fourCC("DMDL"):
            case ESM::fourCC("DMDT"):
                reader.skipSubRecordData();
                break;
            default:
                throw std::runtime_error("ESM4::PROJ::load - Unknown subrecord " + ESM::printName(subHdr.typeId));
        }
    }
}
