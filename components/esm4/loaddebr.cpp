#include "loaddebr.hpp"

#include <cstring>
#include <vector>

#include "reader.hpp"

void ESM4::Debris::load(ESM4::Reader& reader)
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
            case ESM::fourCC("DATA"):
            {
                // percentage, model path (zstring), flags
                std::vector<char> raw(subHdr.dataSize);
                reader.get(raw.data(), raw.size());
                if (raw.size() < 2)
                    break;
                Model& model = mModels.emplace_back();
                model.percentage = static_cast<std::uint8_t>(raw[0]);
                const char* path = raw.data() + 1;
                const std::size_t length = strnlen(path, raw.size() - 1);
                model.model.set(std::string(path, length));
                if (1 + length + 1 < raw.size())
                    model.flags = static_cast<std::uint8_t>(raw[1 + length + 1]);
                break;
            }
            default: // MODT
                reader.skipSubRecordData();
                break;
        }
    }
}
