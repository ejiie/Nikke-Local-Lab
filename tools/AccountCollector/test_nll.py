import unittest
from profile_frame_assets import frame_id
from nll import legacy, union_metadata
from collector import CollectorError

class BridgeTests(unittest.TestCase):
    def test_profile_statistic_must_not_be_treated_as_equipped_frame(self):
        # Even a number matching a local frame table key proves no selection.
        for value in (0, 1, 25, 12345, True, None):
            payload={'code':0,'data':{'area_id':83,'avatar_frame':value}}
            self.assertIsNone(frame_id(payload,83))
            self.assertIsNone(frame_id(payload,84))

    def test_legacy_excludes_auth_and_duplicate_roster(self):
        roster=[{'name_code':123}]
        env={'characters':roster,'rosterAfter':roster,'responses':[
            {'route':route,'response':{'code':0,'data':data}}
            for route,data in [('Game/GetUserCharacters',{'characters':roster}),
                ('Game/GetUserProfileBasicInfo',{'basic_info':{'nickname':'synthetic'}}),
                ('Game/GetUserCharacters',{'characters':roster}),('Login',{'token':'synthetic-secret'})]]}
        out=legacy(env)
        self.assertEqual(len(out['phase_1_initial_load']),2)
        self.assertNotIn('synthetic-secret',str(out))
        env['rosterAfter']=[]
        with self.assertRaises(CollectorError):legacy(env)
    def test_union_identity_is_not_name_and_never_exposes_remote_id(self):
        card={'nikke_area_id':83,'guild_name':'Synthetic','guild_level':3,'guild_id':'synthetic-id','guild_icon':1}
        first=union_metadata({'code':0,'data':{'card':card}},83,b'x'*32)
        self.assertEqual(first['status'],'member');self.assertNotIn('synthetic-id',str(first))
        card['guild_name']='Renamed'
        self.assertEqual(first['fingerprint'],union_metadata({'code':0,'data':{'card':card}},83,b'x'*32)['fingerprint'])
        with self.assertRaises(CollectorError):union_metadata({'code':0,'data':{'card':card}},81,b'x'*32)
        self.assertEqual(union_metadata({'code':0,'data':{}},83,b'x'*32),{'status':'none'})

if __name__=='__main__':unittest.main()
